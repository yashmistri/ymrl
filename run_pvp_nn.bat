@echo off
setlocal
cd /d "%~dp0"
set "GODOT_EXE=C:\Users\mrmis\Documents\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64.exe"
if not exist "%GODOT_EXE%" set "GODOT_EXE=C:\Users\mrmis\Documents\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
"%GODOT_EXE%" res://scenes/3d/squad_pvp.tscn --nn
