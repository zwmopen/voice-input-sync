Set WshShell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

' 获取脚本所在目录
scriptPath = fso.GetParentFolderName(WScript.ScriptFullName)

' 启动HTTP服务器（最小化，无窗口）
WshShell.Run "cmd /c cd /d """ & scriptPath & """ && start /min python -m http.server 8000", 0, False
WScript.Sleep 2000

' 启动WebSocket服务器（最小化，无窗口）
WshShell.Run "cmd /c cd /d """ & scriptPath & """ && start /min python server.py", 0, False
WScript.Sleep 1000

' 启动客户端（最小化，无窗口）
WshShell.Run "cmd /c cd /d """ & scriptPath & """ && start /min python client.py", 0, False
