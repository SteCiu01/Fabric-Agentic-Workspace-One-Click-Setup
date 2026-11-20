@echo off
REM Runs the full Pester test suite in this folder.
REM Uses %~dp0 so the path works for any user / any clone location.
REM Exit code 0 only when no test failed; anything else: failed tests, or the run did not start.
setlocal

set "TESTS_DIR=%~dp0"

echo Running Pester tests in "%TESTS_DIR%"
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester; $r = Invoke-Pester -Path '%TESTS_DIR%' -Output Detailed -PassThru; if ($r -and $r.Result -eq 'Passed' -and $r.FailedCount -eq 0) { exit 0 } else { exit 1 }"
set "TESTS_EXIT=%ERRORLEVEL%"

echo.
if "%TESTS_EXIT%"=="0" echo RESULT: PASSED - no test failed. Skipped and not-run tests are counted in the summary above.
if not "%TESTS_EXIT%"=="0" echo RESULT: FAILED - tests failed or the run did not start. Exit code %TESTS_EXIT%.
echo Press any key to close.
pause >nul
endlocal & exit /b %TESTS_EXIT%
