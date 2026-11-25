@echo off
setlocal
cd /d "%~dp0"

echo ======================================================================
echo Launching Squad Battle: NavMesh Navigation & Tactical Anchors!
echo 4 Specialized Arenas: Pillars, Dividers, Alcoves, Compound
echo Camera Controls: I/J/K/L to Pan | U/O to Zoom | Shift Boost | H Reset
echo Combat Balance: Random Lv 1-3, 8.0 Medic Heal, 5%% 3x Crit, Guard Breaks
echo Auto-resets on victory and rotates arenas every round!
echo ======================================================================

set "GODOT_EXE=C:\Users\mrmis\Documents\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64.exe"
if not exist "%GODOT_EXE%" set "GODOT_EXE=C:\Users\mrmis\Documents\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"

if exist "%GODOT_EXE%" (
    echo Starting Godot with Squad Battle Nav...
    "%GODOT_EXE%" res://scenes/3d/squad_battle_nav.tscn %*
) else if exist "build\YMRL.exe" (
    echo Starting YMRL.exe...
    "build\YMRL.exe" res://scenes/3d/squad_battle_nav.tscn %*
) else if exist "build\Squad3.exe" (
    echo Starting Squad3.exe...
    "build\Squad3.exe" res://scenes/3d/squad_battle_nav.tscn %*
) else (
    echo [ERROR] Could not find Godot executable at %GODOT_EXE%
    pause
)
