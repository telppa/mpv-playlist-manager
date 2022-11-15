; 改自 https://gist.github.com/tmplinshi/05c1c395b86916f79b01d66400e6180f
; 修复了中文路径不支持的问题
; 修复了部分快捷键失效的问题
; 增加了 m3u m3u8 格式的支持
; 增加了地址订阅功能
; 增加了频道搜索功能
; 以外挂插件形式附着

#NoEnv
#SingleInstance Ignore
SetBatchLines -1

GUI:
	; GUI
	Gui +Resize +MinSize +MinSizex480 +ToolWindow +HWNDgui_hwnd
	Gui Margin, 8, 8
	Gui Add, Edit, Section w260 h25 vSearchStr gSearchChange
	Gui Add, StatusBar, vMainStatusBar, 搜索语法： “cc 1080” 可匹配 CCTV-1(1080p)
	Gui Font, s15
	Gui Add, ListBox, xs w260 h400 vMainListBox gSelectLB HScroll 0x100 Hidden
	Gui Add, TreeView, xs yp w260 h400 vMainTreeView gSelectTV HScroll
	
	; --idle 空闲不退出 --input-ipc-server 启用管道通信
	; --wid=%hwnd% 实现内嵌 hwnd 是任意控件或 GUI 的句柄
	if (FileExist("mpv.exe"))
		Run, mpv.exe --idle --input-ipc-server=\\.\pipe\mpvsocket,,, mpv_pid
	else
	{
		MsgBox 请将本程序放在 mpv.exe 所在目录。
		ExitApp
	}
	
	; 托盘菜单
	Menu Tray, NoStandard
	Menu Tray, Add, 显示, GuiShow
	Menu Tray, Add, 订阅, Subscribe
	Menu Tray, Add, 主页, HomePage
	Menu Tray, Add, 退出, SaveAndExit
	Menu Tray, Default, 显示
	Menu Tray, Icon, mpv.exe
	
	if (FileExist("mpv_playlist.json"))
	{
		data_tv := load_json("mpv_playlist.json")
		need_to_update := A_Now
		EnvSub, need_to_update, % data_tv["last_update_time"], Days
	}
	
	WinWait ahk_pid %mpv_pid%
	WinGet mpv_hwnd, ID, ahk_pid %mpv_pid%
	Gui Show, Hide h480 ; 这样可以减轻窗口首次出现时闪烁
	
	; 固定在 mpv 的右侧，并且随 mpv 退出
	exDock := new Dock(mpv_hwnd, gui_hwnd)
	exDock.Position("R")
	exDock.CloseCallback := Func("CloseCallback")
	Gui Show,, playlist manager v1.3
	
	; 检查订阅列表是否需要更新
	if (data_tv["url"] and need_to_update >= 1)
		UpdateFromURL(data_tv["url"])
return

GuiDropFiles:
	SplitPath A_GuiEvent, , , drop_file_ext
	if drop_file_ext in m3u,m3u8,txt
		data_tv := load_m3u(A_GuiEvent)
	else
		mpv_command(["loadfile", A_GuiEvent])
return

; 按照官方的格式定义， #EXTINF 标签中是不会有 group-title 属性的，但实际上却有，因此只能按照实际进行解析
load_m3u(path, url := "")
{
	global MainStatusBar
	
	Critical
	
	_data := {}
	
	f := FileOpen(path, "r", "utf-8")
	
	GuiControl,, MainStatusBar, 解析中...
	while (!f.AtEOF)
	{
		line := f.ReadLine()
		
		if (SubStr(line, 1, 8) == "#EXTINF:")
		{
			oline := StrSplit(SubStr(line, 9), ",")
			RegExMatch(oline[1], "group-title=""(.+)""", OutputVar)
			group := OutputVar1
			title := oline[2]
			
			loop
			{
				suffix := (A_Index=1) ? "" : "(" A_Index ")"
				
				if (_data[group, title suffix]) ; 名称重复的自动添加序号
					continue
				else
				{
					_data[group, title suffix] := RegExReplace(f.ReadLine(), "\R$")
					break
				}
			}
		}
	}
	
	f.Close()
	
	; 去重
	GuiControl,, MainStatusBar, 去重中...
	temp := {}
	for k, v in _data
	{
		for k2, v2 in v
		{
			temp[v2] := {(k):k2}
			n++ ; 去重前的数量
		}
	}
	_data := {}
	for k, v in temp
	{
		for k2, v2 in v
		{
			_data[k2, v2] := k
			m++ ; 去重后的数量
		}
	}
	
	data := {url:url, last_update_time:A_Now, data:_data}
	
	show_data_tv(data, m, n)
	
	return data
}

load_json(path)
{
	Critical
	
	FileRead var, %path%
	data := json.load(var)
	
	for k, v in data["data"]
		for k2, v2 in v
			m++
	
	show_data_tv(data, m)
	
	return data
}

show_data_tv(data, m, n := 0)
{
	global needToShowBlankListBoxFirst, MainStatusBar, MainTreeView, MainListBox, pre_status
	
	TV_Delete()
	needToShowBlankListBoxFirst := true
	GuiControl,, MainStatusBar, 加载中...
	Guicontrol, Show, MainTreeView
	Guicontrol, Hide, MainListBox
	
	for k, v in data["data"]
	{
		if (k = "") ; 无分类
		{
			for k2, v2 in v
				TV_Add(k2)
		}
		else
		{
			group_id := TV_Add(k)
			for k2, v2 in v
				TV_Add(k2, group_id)
		}
	}
	GuiControl, , MainStatusBar, % m<n ? Format("已加载 {} 项（去重 {} 项）。", m, n-m) : Format("已加载 {} 项。", m)
	
	GuiControlGet pre_status, , MainStatusBar
}

; 命令列表 https://mpv.io/manual/stable/#list-of-input-commands 以及 https://mpv.io/manual/stable/#id7
; 改自 https://www.autohotkey.com/boards/viewtopic.php?t=9858
mpv_command(command, encoding := "UTF-8")
{
	command  := json.dump({"command":command}) "`n"
	in_size  := StrPutVar(command, in, encoding)
	
	out_size := 4096
	VarSetCapacity(out, out_size, 0)
	
	if !DllCall("CallNamedPipe"
						, "Str", "\\.\pipe\mpvsocket"
						, "Ptr", &in
						, "UInt", in_size
						, "Ptr", &out
						, "UInt", out_size    ; 相当于设置 out 的最大长度
						, "UInt*", bytes_read ; 实际 out 大小
						, "UInt", 500)        ; 超时
		throw Exception("CallNamedPipe failed with error " A_LastError)
	
	return json.load(StrGet(&out, encoding))
}

; return bytes !!!
StrPutVar(string, ByRef var, encoding)
{
	factor := (encoding="utf-16"||encoding="cp1200") ? 2 : 1
	VarSetCapacity(var, StrPut(string, encoding) * factor)
	return StrPut(string, &var, encoding) * factor
}

GuiShow:
	Gui Show
	exDock.Position("R")
return

Subscribe:
	InputBox subscribe_url, 订阅, 输入要订阅的地址`n`n订阅成功后将每天更新1次
	if (ErrorLevel = 0)
		UpdateFromURL(subscribe_url)
return

UpdateFromURL(url)
{
	global data_tv
	
	options=
	(`%
	ExpectedStatusCode:200
	NumberOfRetries:3
	)
	path := A_Temp "\mpv_playlist.m3u"
	
	mpv_command(["show-text", "更新订阅中...", "180000"])
	WinHttp.Download(url, options,,, path)
	if (WinHttp.StatusCode = 200)
		succeed := true
	else if (url ~= "^https://raw.github")
	{
		mpv_command(["show-text", "更新订阅中（使用加速节点）...", "180000"])
		WinHttp.Download("https://ghproxy.com/" url, options,,, path)  ; 多次下载失败则尝试使用 https://ghproxy.com/ 加速
		if (WinHttp.StatusCode = 200)
			succeed := true, url := "https://ghproxy.com/" url
	}
	
	if (succeed)
	{
		data_tv := load_m3u(path, url)
		FileDelete %path%
		mpv_command(["show-text", "更新订阅成功", "5000"])
	}
	else
	{
		if (url = data_tv["url"]) ; 每天的自动更新订阅失败时更新时间、新的订阅失败时不更新时间
			data_tv["last_update_time"] := A_Now
		mpv_command(["show-text", "更新订阅失败", "5000"])
	}
}

HomePage:
	Run https://github.com/telppa/mpv-playlist-manager
return
	
CloseCallback(self)
{
	gosub SaveAndExit
}

SaveAndExit:
	if (IsObject(data_tv))
	{
		FileDelete mpv_playlist.json
		FileAppend % json.dump(data_tv), mpv_playlist.json
	}
	ExitApp
return

GuiEscape:
GuiClose:
	Gui Hide
	exDock.Position("Z") ; 使用一个错误的参数让窗口定位暂时失效
return

GuiSize:
	GuiControl, Move, SearchStr, % Format("w{}", A_GuiWidth - 16)
	GuiControl, Move, MainListBox, % Format("w{} h{}", A_GuiWidth - 16, A_GuiHeight - 70)
	GuiControl, Move, MainTreeView, % Format("w{} h{}", A_GuiWidth - 16, A_GuiHeight - 70)
return

SelectTV:
SelectLB:
  if (A_GuiEvent != "DoubleClick") ; 只处理双击
    return
	
	load_sel_item()
return

load_sel_item()
{
	global MainTreeView, data_tv, data_lb, mpv_path, mpv_title
	
	GuiControlGet is_tv_show, Visible, MainTreeView
	
	if (is_tv_show)
	{
		tv_sel_id := TV_GetSelection()
		
		if (TV_GetChild(tv_sel_id)) ; 存在子项则返回
			return
		
		TV_GetText(group, TV_GetParent(tv_sel_id))
		TV_GetText(title, tv_sel_id)
		
		mpv_path  := data_tv["data", group, title]
		mpv_title := group ? group "-" title : title
	}
	else
	{
		GuiControlGet, text,, MainListbox
		
		mpv_path  := data_lb[text]
		mpv_title := text
	}
	
	mpv_command(["loadfile", mpv_path])
	
	SetTimer ChangeMpvTitle, 500
}

ChangeMpvTitle:
	if (mpv_command(["get_property", "time-pos"])["data"]) ; 开始播放后再设置标题，否则会被覆盖
	{
		SetTimer ChangeMpvTitle, Off
		
		if (mpv_command(["get_property", "path"])["data"] = mpv_path) ; 确保正在播放的是我们刚才选择的内容
			WinSetTitle ahk_id %mpv_hwnd%, , %mpv_title%
		
		WinActivate ahk_id %mpv_hwnd%
	}
return

SearchChange:
	SetTimer ShowSearchResults, -500
return

ShowSearchResults:
  GuiControlGet, SearchStr,, SearchStr
  
  if (SearchStr = "")
  {
    needToShowBlankListBoxFirst := true
		GuiControl,, MainStatusBar, %pre_status%
    Guicontrol, Show, MainTreeView
    Guicontrol, Hide, MainListBox
    return
  }
  else if (needToShowBlankListBoxFirst)
  {
    needToShowBlankListBoxFirst := false
		GuiControlGet pre_status, , MainStatusBar
    GuiControl,, MainListBox, |
    Guicontrol, Show, MainListBox
    Guicontrol, Hide, MainTreeView
  }
  
	data_lb := show_search_results(SearchStr)
return

show_search_results(str)
{
	global data_tv, MainListbox
	
	data := {}
	
	for group, temp in data_tv["data"]
	{
		for title, url in temp
		{
			item_name_lb := group ? group "-" title : title
			
			; 支持 “a b” 匹配 “acdbef”
			for k, v in StrSplit(str, " ")
				if (!InStr(item_name_lb, v))
					continue, 2
			
			list_lb .= "|" item_name_lb
			
			loop
			{
				suffix := (A_Index=1) ? "" : "(" A_Index ")"
				
				if (data[item_name_lb suffix]) ; 名称重复的自动添加序号
					continue
				else
				{
					data[item_name_lb suffix] := url
					break
				}
			}
		}
	}
	
  GuiControl,, MainListBox, % list_lb ? list_lb : "|"
  GuiControl, Choose, MainListBox, 1
	GuiControl,, MainStatusBar, % Format("已匹配 {} 项。", data.Count())
	
	return data
}

; 不内嵌 mpv 的情况下，此函数完全不需要使用
WM_KeyDown(wParam, lParam, nMsg, hWnd)
{
	; static _ := OnMessage(0x100, "WM_KeyDown")
	
	switch wParam
	{
		case 37 :key := "Left"
		case 38 :key := "Up"
		case 39 :key := "Right"
		case 40 :key := "Down"
		default :key := GetKeyName(Format("vk{:x}", wParam))
	}
	
	ControlSend, mpv1, % "{" key "}", A
}

#Include <Dock>
#Include <cjson>
#Include <WinHttp>