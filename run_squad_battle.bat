@echo off
setlocal
cd /d "%~dp0"

echo =======================================================
echo Launching Squad Battle: 3v3 Neural Network Inference!
echo Blue Team vs Red Team (res://models/squad_rl_500k.onnx)
echo Everything auto-resets when one team wins!
echo Controls:
echo   - R: Reset match
echo   - K: Defeat Red squad (test reset)
echo   - L: Defeat Blue squad (test reset)
echo =======================================================

set "GODOT_EXE=C:\Users\mrmis\Documents\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64.exe"
if not exist "%GODOT_EXE%" set "GODOT_EXE=C:\Users\mrmis\Documents\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"

if exist "%GODOT_EXE%" (
    echo Starting Godot...
    "%GODOT_EXE%" res://scenes/3d/squad_battle.tscn
) else if exist "build\Squad3.exe" (
    echo Starting Squad3.exe...
    "build\Squad3.exe"
) else (
    echo [ERROR] Could not find Godot executable at %GODOT_EXE%
    pause
)
