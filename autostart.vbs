Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "cmd /c cd /d D:\AICode\voice-input-sync && start /min python server.py", 0, False
WScript.Sleep 2000
WshShell.Run "cmd /c cd /d D:\AICode\voice-input-sync && start /min python -m http.server 8000", 0, False
WScript.Sleep 1000
WshShell.Run "cmd /c cd /d D:\AICode\voice-input-sync && start /min python client.py", 0, False
