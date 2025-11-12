@echo off
setlocal enabledelayedexpansion

rem Use PowerShell to display a file selection dialog
for /f "delims=" %%a in ('powershell -command "[System.Windows.Forms.OpenFileDialog]$ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = 'CSV Files|*.csv'; if($ofd.ShowDialog() -eq 'OK'){ $ofd.FileName }"') do (
    set input_file=%%a
)

rem If no file is selected, exit the script
if not defined input_file (
    echo No file selected, exiting...
    exit /b
)

echo Selected file: %input_file%

rem Read the first line (header) of the CSV file
for /f "tokens=* delims=" %%a in ('type "%input_file%" ^| findstr /n "^"') do (
    set line=%%a
    set /a line_number+=1
    if !line_number! == 1 (
        set header=%%a
    )
)

rem Initialize counters for parts and line numbers
set /a part=1
set /a count=0

rem Write the header to the first output file
echo %header% > part_!part!.csv

rem Loop through the remaining lines of the input file (skipping the header)
for /f "skip=1 tokens=* delims=" %%b in ('type "%input_file%"') do (
    set /a count+=1
    rem Append the current line to the current file
    echo %%b >> part_!part!.csv

    rem Every 4000 lines, create a new file and reset the line counter
    if !count! geq 4000 (
        set /a part+=1
        set /a count=0
        rem Write the header to the new file
        echo %header% > part_!part!.csv
    )
)

echo Process completed!
