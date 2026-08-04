import Foundation

enum QuestionBankSchema {
    static let currentVersion = 2

    static func migrate(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at REAL NOT NULL
            )
            """)
        for version in 1...currentVersion {
            try db.transaction {
                // Recheck after BEGIN IMMEDIATE. The capture and practice apps may
                // launch together and race while opening a brand-new shared file.
                guard try db.scalarInt(
                    "SELECT COUNT(*) FROM schema_migrations WHERE version = ?",
                    [.integer(Int64(version))]
                ) == 0 else { return }
                switch version {
                case 1: try migration1(db)
                case 2: try migration2(db)
                default: break
                }
                try db.execute(
                    "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?)",
                    [.integer(Int64(version)), .real(Date().timeIntervalSince1970)]
                )
            }
        }
    }

    private static func migration1(_ db: SQLiteDatabase) throws {
        let statements = [
            """
            CREATE TABLE settings (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                normal_review_interval_days INTEGER NOT NULL DEFAULT 7 CHECK (normal_review_interval_days >= 0),
                wrong_required_consecutive_correct INTEGER NOT NULL DEFAULT 3 CHECK (wrong_required_consecutive_correct > 0),
                questions_per_session INTEGER,
                updated_at REAL NOT NULL
            )
            """,
            """
            INSERT INTO settings(id, normal_review_interval_days, wrong_required_consecutive_correct, questions_per_session, updated_at)
            VALUES (1, 7, 3, NULL, 0)
            """,
            """
            CREATE TABLE questions (
                id TEXT PRIMARY KEY,
                external_id TEXT NOT NULL UNIQUE,
                stem TEXT NOT NULL,
                question_type TEXT NOT NULL CHECK (question_type IN ('single_choice', 'multiple_choice')),
                explanation TEXT NOT NULL DEFAULT '',
                source TEXT,
                source_image_path TEXT,
                source_image_hash TEXT,
                captured_at REAL,
                active INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE options (
                id TEXT PRIMARY KEY,
                question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                original_label TEXT,
                text TEXT NOT NULL,
                is_correct INTEGER NOT NULL CHECK (is_correct IN (0, 1)),
                sort_order INTEGER NOT NULL,
                active INTEGER NOT NULL DEFAULT 1,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX options_question_active ON options(question_id, active, sort_order)",
            """
            CREATE TABLE question_state (
                question_id TEXT PRIMARY KEY REFERENCES questions(id) ON DELETE CASCADE,
                last_answered_at REAL,
                total_attempts INTEGER NOT NULL DEFAULT 0,
                correct_attempts INTEGER NOT NULL DEFAULT 0,
                wrong_attempts INTEGER NOT NULL DEFAULT 0,
                is_wrong_book INTEGER NOT NULL DEFAULT 0,
                consecutive_correct INTEGER NOT NULL DEFAULT 0,
                added_to_wrong_at REAL,
                removed_from_wrong_at REAL,
                updated_at REAL NOT NULL
            )
            """,
            "CREATE INDEX question_state_wrong ON question_state(is_wrong_book, updated_at)",
            """
            CREATE TABLE practice_sessions (
                id TEXT PRIMARY KEY,
                mode TEXT NOT NULL CHECK (mode IN ('normal', 'wrong_book')),
                status TEXT NOT NULL CHECK (status IN ('active', 'completed')),
                current_index INTEGER NOT NULL DEFAULT 0,
                total_items INTEGER NOT NULL,
                random_seed INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                completed_at REAL
            )
            """,
            "CREATE INDEX practice_sessions_active ON practice_sessions(status, updated_at DESC)",
            """
            CREATE TABLE session_items (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES practice_sessions(id) ON DELETE CASCADE,
                question_id TEXT NOT NULL REFERENCES questions(id),
                position INTEGER NOT NULL,
                question_snapshot_json TEXT NOT NULL,
                option_order_json TEXT NOT NULL,
                correct_option_ids_json TEXT NOT NULL,
                answered_at REAL,
                attempt_id TEXT UNIQUE,
                UNIQUE(session_id, position),
                UNIQUE(session_id, question_id)
            )
            """,
            "CREATE INDEX session_items_session_position ON session_items(session_id, position)",
            """
            CREATE TABLE attempts (
                id TEXT PRIMARY KEY,
                submission_token TEXT NOT NULL UNIQUE,
                session_id TEXT NOT NULL REFERENCES practice_sessions(id),
                session_item_id TEXT NOT NULL REFERENCES session_items(id),
                question_id TEXT NOT NULL REFERENCES questions(id),
                mode TEXT NOT NULL,
                submitted_at REAL NOT NULL,
                selected_option_ids_json TEXT NOT NULL,
                displayed_option_order_json TEXT NOT NULL,
                correct_option_ids_json TEXT NOT NULL,
                is_correct INTEGER NOT NULL,
                marked_unsure INTEGER NOT NULL,
                was_in_wrong_book INTEGER NOT NULL,
                is_in_wrong_book INTEGER NOT NULL,
                wrong_progress_before INTEGER NOT NULL,
                wrong_progress_after INTEGER NOT NULL,
                removed_from_wrong_book INTEGER NOT NULL,
                explanation_snapshot TEXT NOT NULL,
                result_json TEXT
            )
            """,
            "CREATE INDEX attempts_question_time ON attempts(question_id, submitted_at DESC)",
            "CREATE INDEX attempts_session ON attempts(session_id, submitted_at)",
            """
            CREATE TRIGGER attempts_are_append_only_update
            BEFORE UPDATE ON attempts BEGIN
                SELECT RAISE(ABORT, 'attempts are append-only');
            END
            """,
            """
            CREATE TRIGGER attempts_are_append_only_delete
            BEFORE DELETE ON attempts BEGIN
                SELECT RAISE(ABORT, 'attempts are append-only');
            END
            """,
            """
            CREATE TABLE change_log (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                source_app TEXT NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                action TEXT NOT NULL,
                payload_json TEXT,
                created_at REAL NOT NULL
            )
            """,
            "CREATE INDEX change_log_created ON change_log(sequence, created_at)"
        ]
        for statement in statements { try db.execute(statement) }
    }

    private static func migration2(_ db: SQLiteDatabase) throws {
        let statements = [
            """
            CREATE TABLE knowledge_points (
                id TEXT PRIMARY KEY,
                normalized_name TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE question_knowledge_points (
                question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
                knowledge_point_id TEXT NOT NULL REFERENCES knowledge_points(id) ON DELETE CASCADE,
                PRIMARY KEY(question_id, knowledge_point_id)
            )
            """,
            """
            CREATE TABLE capture_events (
                id TEXT PRIMARY KEY,
                source_image_hash TEXT NOT NULL UNIQUE,
                question_id TEXT NOT NULL REFERENCES questions(id),
                source_image_path TEXT NOT NULL,
                captured_at REAL NOT NULL,
                imported_at REAL NOT NULL
            )
            """,
            "CREATE INDEX capture_events_question ON capture_events(question_id, captured_at DESC)"
        ]
        for statement in statements { try db.execute(statement) }
    }
}
