' =====================================================================
'  launch.vbs -- hidden launcher for update-gui.ps1
'  Keeps the UAC prompt, but starts PowerShell with SW_HIDE so no console
'  window flashes. wscript.exe has no console of its own.
' =====================================================================
Option Explicit
Dim fso, sh, base, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("Shell.Application")

base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = base & "\update-gui.ps1"

If Not fso.FileExists(ps1) Then
    ' No popup: write the failure next to the start beacon and exit quietly.
    On Error Resume Next
    Dim ef
    Set ef = fso.CreateTextFile(fso.GetSpecialFolder(2) & "\DSH-update-launch-error.txt", True)
    If Err.Number = 0 Then
        ef.WriteLine Now & "  [launch] update-gui.ps1 not found: " & ps1
        ef.Close
    End If
    On Error GoTo 0
    WScript.Quit 1
End If

Dim beacon
beacon = fso.GetSpecialFolder(2) & "\DSH-update-launch.txt"
On Error Resume Next
Dim bf
Set bf = fso.CreateTextFile(beacon, True)
If Err.Number = 0 Then
    bf.WriteLine "launch.vbs 已运行 " & Now & "  目标=" & ps1
    bf.Close
End If
Err.Clear
On Error GoTo 0

cmd = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """"
sh.ShellExecute "powershell.exe", cmd, base, "runas", 0
