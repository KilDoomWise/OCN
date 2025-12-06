local component = require("component")
local event = require("event")
local internet = require("internet")
local filesystem = require("filesystem")
local unicode = require("unicode")

local gpu = component.gpu
local screenW, screenH = gpu.getResolution()

local winW = math.floor(screenW * 0.7)
local winH = math.floor(screenH * 0.75)
local winX = math.floor((screenW - winW) / 2)
local winY = math.floor((screenH - winH) / 2)

local sidebarW = 20

local state = {
    page = 1,
    role = nil,
    libraries = {},
    installing = false,
    installLog = {},
    installProgress = 0
}

local libraryConfig = {
    {
        id = "OCNP", 
        file = "OCNP.lua", 
        path = "/lib/",
        url = "https://raw.githubusercontent.com/KilDoomWise/OCNP/refs/heads/main/src/OCNP.lua",
        required = {"router", "provider"}
    },
    {
        id = "utils", 
        file = "utils.lua", 
        path = "/lib/",
        url = "https://raw.githubusercontent.com/KilDoomWise/OCN/refs/heads/main/lib/utils.lua",
        required = {"router", "provider"}
    },
    {
        id = "bgp", 
        file = "bgp.lua", 
        path = "/lib/",
        url = "https://raw.githubusercontent.com/KilDoomWise/OCN/refs/heads/main/lib/bgp.lua",
        required = {"provider"}
    },
    {
        id = "dhcp", 
        file = "dhcp.lua", 
        path = "/lib/",
        url = "https://raw.githubusercontent.com/KilDoomWise/OCN/refs/heads/main/lib/dhcp.lua",
        required = {"router", "provider"}
    },
    {
        id = "router_bin", 
        file = "router.lua", 
        path = "/bin/",
        url = "https://raw.githubusercontent.com/KilDoomWise/OCN/refs/heads/main/bin/router.lua",
        required = {"router"}
    },
    {
        id = "isp_bin", 
        file = "isp.lua", 
        path = "/bin/",
        url = "https://raw.githubusercontent.com/KilDoomWise/OCN/refs/heads/main/bin/isp.lua",
        required = {"provider"}
    }
}

local steps = {
    {id = 1, name = "Роль"},
    {id = 2, name = "Файлы"},
    {id = 3, name = "Сводка"},
    {id = 4, name = "Установка"}
}

local colors = {
    bg = 0x000000,
    windowBg = 0x1a1a1a,
    sidebar = 0x0f0f0f,
    accent = 0xffffff,
    text = 0xffffff,
    textDim = 0x4b4b4b,
    textMid = 0x878787,
    success = 0x00ff00,
    error = 0xff0000,
    buttonBg = 0x333333,
    buttonAccent = 0xffffff,
    cardBg = 0x1a1a1a,
    cardSelected = 0x2d2d2d,
    progressFill = 0xffffff,
    progressEmpty = 0x333333
}

local function fill(x, y, w, h, bg, char)
    gpu.setBackground(bg)
    gpu.fill(x, y, w, h, char or " ")
end

local function text(x, y, fg, bg, str)
    if bg then gpu.setBackground(bg) end
    gpu.setForeground(fg)
    gpu.set(x, y, str)
end

local function getButtonWidth(label)
    return unicode.len(label) + 4
end

local function drawButton(x, y, label, bg, fg)
    local w = getButtonWidth(label)
    
    gpu.setBackground(colors.windowBg)
    gpu.setForeground(bg)
    gpu.set(x, y, "⣠")
    gpu.set(x + 1, y, string.rep("▄", w - 2))
    gpu.set(x + w - 1, y, "⣄")
    
    gpu.setBackground(bg)
    gpu.setForeground(fg)
    gpu.set(x, y + 1, string.rep(" ", w))
    gpu.set(x + 2, y + 1, label)
    
    gpu.setBackground(colors.windowBg)
    gpu.setForeground(bg)
    gpu.set(x, y + 2, "⠙")
    gpu.set(x + 1, y + 2, string.rep("▀", w - 2))
    gpu.set(x + w - 1, y + 2, "⠋")
    
    return {x = x, y = y, w = w, h = 3, action = nil}
end

local function drawCard(x, y, w, h, title, desc, selected)
    local bg = selected and colors.cardSelected or colors.cardBg
    
    fill(x, y, w, h, bg)
    
    if selected then
        fill(x, y, 1, h, colors.accent)
    end
    
    text(x + 3, y + 1, colors.text, bg, title)
    text(x + 3, y + 2, colors.textDim, bg, desc)
end

local function drawProgressBar(x, y, w, progress)
    local filledW = math.floor(w * progress)
    
    gpu.setBackground(colors.windowBg)
    gpu.setForeground(colors.progressFill)
    
    if filledW > 0 then
        gpu.set(x, y, string.rep("━", filledW))
    end
    
    if w - filledW > 0 then
        gpu.setForeground(colors.progressEmpty)
        gpu.set(x + filledW, y, string.rep("─", w - filledW))
    end
end

local function clearScreen()
    fill(1, 1, screenW, screenH, colors.bg)
end

local function checkLibraries()
    state.libraries = {}
    for _, lib in ipairs(libraryConfig) do
        local fullPath = lib.path .. lib.file
        local exists = filesystem.exists(fullPath)
        
        local needed = false
        for _, role in ipairs(lib.required) do
            if role == state.role then
                needed = true
                break
            end
        end
        
        if needed then
            state.libraries[lib.id] = {
                file = lib.file,
                path = lib.path,
                url = lib.url,
                exists = exists,
                status = exists and "update" or "install"
            }
        end
    end
end

local function drawWindow()
    clearScreen()
    
    fill(winX, winY, winW, winH, colors.windowBg)
    fill(winX, winY, sidebarW, winH, colors.sidebar)
    
    text(winX + 3, winY + 2, colors.accent, colors.sidebar, "OCN")
    text(winX + 3, winY + 3, colors.textDim, colors.sidebar, "Installer")
    
    local stepsY = winY + 6
    for i, step in ipairs(steps) do
        local isCurrent = i == state.page
        local isPast = i < state.page
        
        local icon, textColor
        if isPast then
            icon = "+"
            textColor = colors.textMid
        elseif isCurrent then
            icon = ">"
            textColor = colors.text
        else
            icon = " "
            textColor = colors.textDim
        end
        
        local stepY = stepsY + (i - 1) * 2
        
        text(winX + 3, stepY, isCurrent and colors.accent or colors.textDim, colors.sidebar, icon)
        text(winX + 5, stepY, textColor, colors.sidebar, step.name)
    end
    
    text(winX + 3, winY + winH - 2, colors.textDim, colors.sidebar, "OCNTeam")
    
    local contentX = winX + sidebarW + 3
    local contentY = winY + 2
    local contentW = winW - sidebarW - 6
    local contentH = winH - 4
    
    return contentX, contentY, contentW, contentH
end

local buttons = {}

local function getButtonY(cy, ch)
    return cy + ch - 2
end

local function drawPage1()
    local cx, cy, cw, ch = drawWindow()
    buttons = {}
    
    text(cx, cy, colors.text, colors.windowBg, "Выберите назначение")
    text(cx, cy + 1, colors.textDim, colors.windowBg, "Для чего будет использоваться этот компьютер?")
    
    local cardH = 4
    local cardY = cy + 4
    drawCard(cx, cardY, cw, cardH, "Роутер", "Организует работу локальной сети", state.role == "router")
    table.insert(buttons, {x = cx, y = cardY, w = cw, h = cardH, action = "router"})
    
    cardY = cardY + cardH + 1
    drawCard(cx, cardY, cw, cardH, "Провайдер", "Связывает сети, работает с пирингами", state.role == "provider")
    table.insert(buttons, {x = cx, y = cardY, w = cw, h = cardH, action = "provider"})
    
    if state.role then
        local label = "Далее"
        local btnW = getButtonWidth(label)
        local btn = drawButton(cx + cw - btnW, getButtonY(cy, ch), label, colors.buttonBg, colors.text)
        btn.action = "next"
        table.insert(buttons, btn)
    end
end

local function drawPage2()
    local cx, cy, cw, ch = drawWindow()
    buttons = {}
    
    local roleName = state.role == "router" and "роутера" or "провайдера"
    text(cx, cy, colors.text, colors.windowBg, "Файлы")
    text(cx, cy + 1, colors.textDim, colors.windowBg, "Будут установлены для " .. roleName)
    
    local treeY = cy + 4
    
    local libFiles = {}
    local binFiles = {}
    
    for id, info in pairs(state.libraries) do
        if info.path == "/lib/" then
            table.insert(libFiles, {id = id, info = info})
        else
            table.insert(binFiles, {id = id, info = info})
        end
    end
    
    table.sort(libFiles, function(a, b) return a.info.file < b.info.file end)
    table.sort(binFiles, function(a, b) return a.info.file < b.info.file end)
    
    text(cx, treeY, colors.textMid, colors.windowBg, "/lib")
    treeY = treeY + 1
    
    for i, lib in ipairs(libFiles) do
        local isLast = i == #libFiles
        local prefix = isLast and "  └ " or "  ├ "
        local statusIcon = lib.info.exists and "~" or "+"
        local statusColor = lib.info.exists and colors.textMid or colors.success
        local statusText = lib.info.exists and " обновить" or " новый"
        
        text(cx, treeY, colors.textDim, colors.windowBg, prefix)
        text(cx + unicode.len(prefix), treeY, statusColor, colors.windowBg, statusIcon)
        text(cx + unicode.len(prefix) + 2, treeY, colors.text, colors.windowBg, lib.info.file)
        text(cx + unicode.len(prefix) + 2 + unicode.len(lib.info.file), treeY, colors.textDim, colors.windowBg, statusText)
        
        treeY = treeY + 1
    end
    
    treeY = treeY + 1
    text(cx, treeY, colors.textMid, colors.windowBg, "/bin")
    treeY = treeY + 1
    
    for i, lib in ipairs(binFiles) do
        local isLast = i == #binFiles
        local prefix = isLast and "  └ " or "  ├ "
        local statusIcon = lib.info.exists and "~" or "+"
        local statusColor = lib.info.exists and colors.textMid or colors.success
        local statusText = lib.info.exists and " обновить" or " новый"
        
        text(cx, treeY, colors.textDim, colors.windowBg, prefix)
        text(cx + unicode.len(prefix), treeY, statusColor, colors.windowBg, statusIcon)
        text(cx + unicode.len(prefix) + 2, treeY, colors.text, colors.windowBg, lib.info.file)
        text(cx + unicode.len(prefix) + 2 + unicode.len(lib.info.file), treeY, colors.textDim, colors.windowBg, statusText)
        
        treeY = treeY + 1
    end
    
    local btn = drawButton(cx, getButtonY(cy, ch), "Назад", colors.buttonBg, colors.text)
    btn.action = "back"
    table.insert(buttons, btn)
    
    local label = "Далее"
    local btnW = getButtonWidth(label)
    btn = drawButton(cx + cw - btnW, getButtonY(cy, ch), label, colors.buttonBg, colors.text)
    btn.action = "next"
    table.insert(buttons, btn)
end

local function drawPage3()
    local cx, cy, cw, ch = drawWindow()
    buttons = {}
    
    text(cx, cy, colors.text, colors.windowBg, "Подтверждение")
    text(cx, cy + 1, colors.textDim, colors.windowBg, "Проверьте настройки перед установкой")
    
    local y = cy + 4
    
    local roleName = state.role == "router" and "Роутер" or "Провайдер"
    text(cx, y, colors.textDim, colors.windowBg, "Режим")
    text(cx + 12, y, colors.text, colors.windowBg, roleName)
    y = y + 2
    
    local libNames = {}
    local binNames = {}
    for id, info in pairs(state.libraries) do 
        if info.path == "/lib/" then
            table.insert(libNames, info.file)
        else
            table.insert(binNames, info.file)
        end
    end
    
    text(cx, y, colors.textDim, colors.windowBg, "/lib")
    y = y + 1
    for _, name in ipairs(libNames) do
        text(cx + 2, y, colors.textMid, colors.windowBg, name)
        y = y + 1
    end
    
    y = y + 1
    text(cx, y, colors.textDim, colors.windowBg, "/bin")
    y = y + 1
    for _, name in ipairs(binNames) do
        text(cx + 2, y, colors.textMid, colors.windowBg, name)
        y = y + 1
    end
    
    local btn = drawButton(cx, getButtonY(cy, ch), "Назад", colors.buttonBg, colors.text)
    btn.action = "back"
    table.insert(buttons, btn)
    
    local label = "Установить"
    local btnW = getButtonWidth(label)
    btn = drawButton(cx + cw - btnW, getButtonY(cy, ch), label, colors.buttonAccent, colors.bg)
    btn.action = "install"
    table.insert(buttons, btn)
end

local maxLogLines = 8

local function addLog(msg, status)
    table.insert(state.installLog, {text = msg, status = status or "info"})
    if #state.installLog > maxLogLines then
        table.remove(state.installLog, 1)
    end
end

local function drawPage4()
    local cx, cy, cw, ch = drawWindow()
    buttons = {}
    
    local statusText = state.installing and "Установка" or "Завершено"
    text(cx, cy, colors.text, colors.windowBg, statusText)
    
    local percent = math.floor(state.installProgress * 100)
    text(cx, cy + 1, colors.textDim, colors.windowBg, percent .. "%")
    
    local barY = cy + 3
    local barW = cw
    drawProgressBar(cx, barY, barW, state.installProgress)
    
    local logStartY = barY + 2
    local logCount = #state.installLog
    
    for i = 1, logCount do
        local log = state.installLog[i]
        local logColor = colors.textDim
        if log.status == "success" then
            logColor = colors.success
        elseif log.status == "error" then
            logColor = colors.error
        elseif log.status == "info" then
            logColor = colors.textMid
        end
        text(cx, logStartY + i - 1, logColor, colors.windowBg, unicode.sub(log.text, 1, cw))
    end
    
    if not state.installing and state.installProgress >= 1 then
        local label = "Закрыть"
        local btnW = getButtonWidth(label)
        local btn = drawButton(cx + cw - btnW, getButtonY(cy, ch), label, colors.buttonBg, colors.text)
        btn.action = "exit"
        table.insert(buttons, btn)
    end
end

local function downloadFile(url, path)
    local success, err = pcall(function()
        local handle = internet.request(url)
        local data = ""
        for chunk in handle do
            data = data .. chunk
        end
        
        local file = io.open(path, "w")
        file:write(data)
        file:close()
    end)
    return success
end

local function doInstall()
    state.installing = true
    state.installProgress = 0
    state.installLog = {}
    
    addLog("Начало установки", "info")
    drawPage4()
    os.sleep(0.3)
    
    if not filesystem.exists("/lib") then
        filesystem.makeDirectory("/lib")
        addLog("Создана папка /lib", "info")
        drawPage4()
    end
    
    if not filesystem.exists("/bin") then
        filesystem.makeDirectory("/bin")
        addLog("Создана папка /bin", "info")
        drawPage4()
    end
    
    local toInstall = {}
    for id, info in pairs(state.libraries) do
        table.insert(toInstall, {id = id, file = info.file, path = info.path, url = info.url})
    end
    
    for i, lib in ipairs(toInstall) do
        local fullPath = lib.path .. lib.file
        
        addLog("Загрузка " .. lib.file, "info")
        drawPage4()
        
        local success = downloadFile(lib.url, fullPath)
        
        if success then
            addLog("OK " .. lib.file, "success")
        else
            addLog("ERR " .. lib.file, "error")
        end
        
        state.installProgress = i / #toInstall
        drawPage4()
        os.sleep(0.2)
    end
    
    addLog("", "info")
    addLog("Установка завершена", "success")
    state.installing = false
    drawPage4()
end

local function isInside(mx, my, btn)
    return mx >= btn.x and mx < btn.x + btn.w and my >= btn.y and my < btn.y + btn.h
end

local function handleClick(mx, my)
    for _, btn in ipairs(buttons) do
        if isInside(mx, my, btn) then
            if btn.action == "router" then
                state.role = "router"
                checkLibraries()
                drawPage1()
            elseif btn.action == "provider" then
                state.role = "provider"
                checkLibraries()
                drawPage1()
            elseif btn.action == "next" then
                state.page = state.page + 1
                if state.page == 2 then drawPage2()
                elseif state.page == 3 then drawPage3()
                elseif state.page == 4 then drawPage4() end
            elseif btn.action == "back" then
                state.page = state.page - 1
                if state.page == 1 then drawPage1()
                elseif state.page == 2 then drawPage2() end
            elseif btn.action == "install" then
                state.page = 4
                doInstall()
            elseif btn.action == "exit" then
                return "exit"
            end
            break
        end
    end
end

local function main()
    drawPage1()
    
    while true do
        local ev = {event.pull()}
        
        if ev[1] == "touch" then
            local result = handleClick(ev[3], ev[4])
            if result == "exit" then
                clearScreen()
                gpu.setBackground(0x000000)
                gpu.setForeground(0xffffff)
                gpu.fill(1, 1, screenW, screenH, " ")
                print("Установка завершена")
                break
            end
        elseif ev[1] == "key_down" and ev[4] == 1 then
            clearScreen()
            gpu.setBackground(0x000000)
            gpu.setForeground(0xffffff)
            gpu.fill(1, 1, screenW, screenH, " ")
            print("Отменено")
            break
        end
    end
end

main()
