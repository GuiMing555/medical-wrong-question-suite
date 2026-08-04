using Microsoft.Data.Sqlite;

namespace MedicalQuestionSuite.Core;

internal sealed class SqliteDatabase : IDisposable
{
    private readonly SqliteConnection _connection;
    private readonly object _gate = new();
    private bool _disposed;

    internal SqliteDatabase(string path)
    {
        var fullPath = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(fullPath)
            ?? throw new InvalidOperationException("数据库路径缺少父目录"));

        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = fullPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Cache = SqliteCacheMode.Shared,
            Pooling = false,
            DefaultTimeout = 5
        };
        _connection = new SqliteConnection(builder.ConnectionString);
        _connection.Open();
        Execute("PRAGMA foreign_keys = ON");
        ConfigureWalMode();
        Execute("PRAGMA synchronous = NORMAL");
        Execute("PRAGMA busy_timeout = 5000");
    }

    internal int Execute(string sql, params object?[] values)
    {
        lock (_gate)
        {
            using var command = CreateCommand(sql, values);
            return command.ExecuteNonQuery();
        }
    }

    internal List<IReadOnlyDictionary<string, object?>> Rows(string sql, params object?[] values)
    {
        lock (_gate)
        {
            using var command = CreateCommand(sql, values);
            using var reader = command.ExecuteReader();
            var rows = new List<IReadOnlyDictionary<string, object?>>();
            while (reader.Read())
            {
                var row = new Dictionary<string, object?>(reader.FieldCount, StringComparer.Ordinal);
                for (var index = 0; index < reader.FieldCount; index++)
                {
                    row[reader.GetName(index)] = reader.IsDBNull(index) ? null : reader.GetValue(index);
                }
                rows.Add(row);
            }
            return rows;
        }
    }

    internal int ScalarInt(string sql, params object?[] values)
    {
        lock (_gate)
        {
            using var command = CreateCommand(sql, values);
            var value = command.ExecuteScalar();
            return value is null or DBNull ? 0 : Convert.ToInt32(value);
        }
    }

    internal T Transaction<T>(Func<T> operation)
    {
        lock (_gate)
        {
            Execute("BEGIN IMMEDIATE");
            try
            {
                var result = operation();
                Execute("COMMIT");
                return result;
            }
            catch
            {
                try { Execute("ROLLBACK"); } catch (SqliteException) { }
                throw;
            }
        }
    }

    internal void Transaction(Action operation) => Transaction(() =>
    {
        operation();
        return true;
    });

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) return;
            _connection.Dispose();
            _disposed = true;
        }
    }

    private SqliteCommand CreateCommand(string sql, IReadOnlyList<object?> values)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(SqliteDatabase));
        var command = _connection.CreateCommand();
        command.CommandText = sql;
        for (var index = 0; index < values.Count; index++)
        {
            command.Parameters.AddWithValue($"$p{index + 1}", values[index] ?? DBNull.Value);
        }
        return command;
    }

    private void ConfigureWalMode()
    {
        SqliteException? lastError = null;
        for (var attempt = 0; attempt < 25; attempt++)
        {
            try
            {
                Rows("PRAGMA journal_mode = WAL");
                return;
            }
            catch (SqliteException exception)
            {
                lastError = exception;
                if (attempt < 24) Thread.Sleep(20);
            }
        }

        throw new QuestionBankException(
            QuestionBankErrorCode.Database,
            "无法启用 SQLite WAL 模式",
            innerException: lastError);
    }
}

internal static class SqliteRowExtensions
{
    internal static string? Text(this IReadOnlyDictionary<string, object?> row, string key) =>
        row.TryGetValue(key, out var value) && value is not null ? Convert.ToString(value) : null;

    internal static int Int32(this IReadOnlyDictionary<string, object?> row, string key, int fallback = 0) =>
        row.TryGetValue(key, out var value) && value is not null ? Convert.ToInt32(value) : fallback;

    internal static long Int64(this IReadOnlyDictionary<string, object?> row, string key, long fallback = 0) =>
        row.TryGetValue(key, out var value) && value is not null ? Convert.ToInt64(value) : fallback;

    internal static double Double(this IReadOnlyDictionary<string, object?> row, string key, double fallback = 0) =>
        row.TryGetValue(key, out var value) && value is not null ? Convert.ToDouble(value) : fallback;
}
