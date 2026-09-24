-- 「Tungsten Edge 开会话」启动器：认领 tungsten-cc:// 链接。进度看板每条工作线的「▶ co / cf / cv」按钮发这个链接，
-- 它直接开一个 Ghostty 窗口、进对应仓库、跑链接里指定的别名，并把开场白灌进 Claude Code 的输入框（不发送）。
-- 由同目录的 install.sh 编译安装；__HELPER__ 在安装时换成装进 app 包里的 open-session.py 的绝对路径。
-- 2026-09-25 起不再弹框选模型（owner 要一点就开）。链接内容任何网页都能发，所以模型与目录只认白名单、
-- 开场白只认看板的格式、而且只灌进输入框不回车——最坏也只是多开一个空会话窗口。

on run
	display dialog "这个小程序只认进度看板发来的 tungsten-cc:// 链接，直接打开没有用。" buttons {"好"} default button 1
end run

on open location theURL
	set helper to "__HELPER__"
	try
		set parsed to do shell script "/usr/bin/python3 " & quoted form of helper & " parse " & quoted form of theURL
	on error errMsg
		activate
		display dialog "链接不合法，没开会话：" & return & errMsg buttons {"好"} default button 1 with icon caution
		return
	end try
	set aliasName to item 2 of paragraphs of parsed
	try
		do shell script "/usr/bin/python3 " & quoted form of helper & " launch " & quoted form of aliasName
	on error errMsg
		activate
		display dialog "没开成：" & return & errMsg buttons {"好"} default button 1 with icon caution
	end try
end open location
