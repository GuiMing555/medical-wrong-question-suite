#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:8.0-alpine"

docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$ROOT_DIR:/work" \
  --workdir /work/Windows \
  --env DOTNET_CLI_HOME=/tmp/dotnet-cli \
  --env NUGET_PACKAGES=/tmp/nuget-packages \
  "$SDK_IMAGE" \
  sh -lc '
    dotnet test MedicalQuestionSuite.Tests/MedicalQuestionSuite.Tests.csproj -c Release
    dotnet build MedicalQuestionPractice.Windows/MedicalQuestionPractice.Windows.csproj -c Release
    dotnet build WrongQuestionCapture.Windows/WrongQuestionCapture.Windows.csproj -c Release
  '
