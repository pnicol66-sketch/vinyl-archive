' Windowless launcher for the publish watcher - wscript.exe runs this with
' zero console flash (the reason a bare powershell.exe task was retired).
CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""C:\Users\User\.claude\Code Projects\vinyl-archive\auto-publish.ps1""", 0, False
