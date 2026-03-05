' Start-Setup.vbs – Startet Setup-WSL.ps1 per Doppelklick
' Umgeht die ExecutionPolicy und startet PowerShell mit dem Script im selben Ordner.
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "Setup-WSL.ps1")

If Not fso.FileExists(ps1Path) Then
    MsgBox "Setup-WSL.ps1 nicht gefunden in:" & vbCrLf & scriptDir, vbCritical, "Fehler"
    WScript.Quit 1
End If

Set shell = CreateObject("WScript.Shell")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """"
shell.Run cmd, 1, False
