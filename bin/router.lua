local component = require("component")
local event = require("event")
local computer = require("computer")
local filesystem = require("filesystem")
local term = require("term")

local OCNP = require("ocnp")
local Utils = require("utils")
local DHCP = require("dhcp")

local Router = {}
Router.VERSION = "2.0"
Router.PORT = 31
Router.HUB_PORT = 32
Router.CONFIG_PATH = "/etc/PetusRouter/conf.oc"
Router.ROUTES_PATH = "/etc/PetusRouter/routes.db"
Router.NAT_PATH = "/etc/PetusRouter/nat.db"
Router.CLEANUP_INTERVAL = 100
Router.SEEN_TTL = 30
Router.NAT_TIMEOUT = 300  -- 5 минут

-- Диапазон внешних портов для NAT
Router.NAT_PORT_MIN = 49152
Router.NAT_PORT_MAX = 65535

Router.HUB = {
  HELLO = "HUB_ROUTER_HELLO",
  ACK = "HUB_ROUTER_ACK",
  NAK = "HUB_ROUTER_NAK"
}

-- === ЛОГИРОВАНИЕ ===
local gpu = component.gpu
local LOG_COLORS = {
  ERROR = 0xFF0000,
  WARNING = 0xFFAA00,
  SUCCESS = 0x00FF00,
  INFO = 0x00AAFF,
  DEBUG = 0xAAAAAA,
  DHCP = 0xFF00FF,
  ROUTE = 0xFFFF00,
  HUB = 0x00FFFF,
  NAT = 0xFF6600
}

local function colorLog(category, message, color)
  local timestamp = string.format("[%.2f]", computer.uptime())
  local prefix = string.format("[%s]", category)
  
  local oldFg = gpu.getForeground()
  
  gpu.setForeground(0xFFFFFF)
  term.write(timestamp .. " ")
  
  gpu.setForeground(color)
  term.write(prefix .. " ")
  
  gpu.setForeground(0xFFFFFF)
  print(message)
  
  gpu.setForeground(oldFg)
end

local function logError(msg) colorLog("ERROR", msg, LOG_COLORS.ERROR) end
local function logWarning(msg) colorLog("WARN", msg, LOG_COLORS.WARNING) end
local function logSuccess(msg) colorLog("OK", msg, LOG_COLORS.SUCCESS) end
local function logInfo(msg) colorLog("INFO", msg, LOG_COLORS.INFO) end
local function logDebug(msg) colorLog("DEBUG", msg, LOG_COLORS.DEBUG) end
local function logDHCP(msg) colorLog("DHCP", msg, LOG_COLORS.DHCP) end
local function logRoute(msg) colorLog("ROUTE", msg, LOG_COLORS.ROUTE) end
local function logHub(msg) colorLog("HUB", msg, LOG_COLORS.HUB) end
local function logNAT(msg) colorLog("NAT", msg, LOG_COLORS.NAT) end

-- === СТРУКТУРЫ ДАННЫХ ===
local config = {}
local leases = {}

-- NAT таблицы (PAT - Port Address Translation)
-- nat_out: ключ = "InternalIP:InternalPort" -> значение = AllocatedExternalPort
-- nat_in:  ключ = AllocatedExternalPort -> значение = {ip, port, mac, ts}
local nat_out = {}
local nat_in = {}
local nextNatPort = Router.NAT_PORT_MIN

local seenCache = nil
local modem = nil
local packetCounter = 0

-- === ФУНКЦИИ КОНФИГУРАЦИИ ===

function Router.loadConfig()
  config = Utils.loadConfig(Router.CONFIG_PATH)

  if not config.interface then
    config.interface = component.modem.address
    config.subnet = "192.168.1.0"
    config.mask = "24"
    config.pool_start = "192.168.1.10"
    config.pool_end = "192.168.1.250"
    config.router_ip = "192.168.1.1"
    config.hub_enabled = "false"
    config.hub_address = ""
    config.external_ip = ""
    config.lease_timeout = "60"
    Utils.saveConfig(Router.CONFIG_PATH, config)
  end

  return config
end

function Router.loadLeases()
  leases = DHCP.loadLeases(Router.ROUTES_PATH)
  return leases
end

function Router.saveLeases()
  DHCP.persistLeases(Router.ROUTES_PATH, leases)
end

function Router.isLocalIP(ip)
  return Utils.inSubnet(ip, config.subnet, tonumber(config.mask))
end

function Router.getMACByIP(ip)
  for mac, lease in pairs(leases) do
    if lease.ip == ip then
      return mac
    end
  end
  return nil
end

-- === NAT ФУНКЦИИ (PAT) ===

-- Аллокация внешнего порта
local function allocateExternalPort()
  local startPort = nextNatPort
  
  repeat
    if not nat_in[nextNatPort] then
      local port = nextNatPort
      nextNatPort = nextNatPort + 1
      if nextNatPort > Router.NAT_PORT_MAX then
        nextNatPort = Router.NAT_PORT_MIN
      end
      return port
    end
    
    nextNatPort = nextNatPort + 1
    if nextNatPort > Router.NAT_PORT_MAX then
      nextNatPort = Router.NAT_PORT_MIN
    end
  until nextNatPort == startPort
  
  return nil  -- Все порты заняты
end

-- Очистка устаревших NAT записей
function Router.cleanupNAT()
  local now = computer.uptime()
  local removed = 0
  
  for extPort, entry in pairs(nat_in) do
    if now - entry.ts > Router.NAT_TIMEOUT then
      -- Удаляем обратную запись
      local outKey = entry.ip .. ":" .. tostring(entry.port)
      nat_out[outKey] = nil
      nat_in[extPort] = nil
      removed = removed + 1
    end
  end
  
  if removed > 0 then
    logNAT(string.format("Cleaned up %d stale NAT entries", removed))
  end
  
  return removed
end

-- === ИСХОДЯЩИЙ NAT ===
-- Модифицирует parsed in-place, возвращает true/false
function Router.processNAT_Out(parsed, senderMAC)
  if not config.external_ip or config.external_ip == "" then
    logWarning("NAT OUT: No external IP configured")
    return false
  end
  
  -- Безопасно получаем порт из payload
  local internalPort = 0
  if parsed.isPayloadTable and type(parsed.payload) == "table" then
    internalPort = parsed.payload.app_port or 0
  end
  
  local natKey = parsed.src .. ":" .. tostring(internalPort)
  local externalPort = nat_out[natKey]
  
  -- Если маппинга нет - создаем
  if not externalPort then
    externalPort = allocateExternalPort()
    if not externalPort then
      logError("NAT OUT: Port pool exhausted!")
      return false
    end
    
    -- Записываем в обе таблицы
    nat_out[natKey] = externalPort
    nat_in[externalPort] = {
      ip = parsed.src,
      port = internalPort,
      mac = senderMAC,
      ts = computer.uptime()
    }
    
    logNAT(string.format("NEW: %s:%d -> %s:%d", 
      parsed.src, internalPort, config.external_ip, externalPort))
  else
    -- Обновляем timestamp
    nat_in[externalPort].ts = computer.uptime()
  end
  
  -- Подменяем SRC на внешний IP
  parsed.src = config.external_ip
  
  -- Подменяем порт в payload (если есть)
  if parsed.isPayloadTable and type(parsed.payload) == "table" then
    parsed.payload.app_port = externalPort
    -- Сохраняем оригинальный порт для отладки
    parsed.payload._nat_original_port = internalPort
  end
  
  return true
end

-- === ВХОДЯЩИЙ NAT ===
-- Модифицирует parsed in-place, возвращает true/false
function Router.processNAT_In(parsed)
  -- Проверяем что пакет адресован нашему external_ip
  if parsed.dst ~= config.external_ip then
    return false, "not_our_ip"
  end
  
  -- Получаем порт назначения
  local destPort = 0
  if parsed.isPayloadTable and type(parsed.payload) == "table" then
    destPort = parsed.payload.app_port or 0
  end
  
  -- Ищем маппинг
  local natEntry = nat_in[destPort]
  if not natEntry then
    logWarning(string.format("NAT IN: No mapping for port %d", destPort))
    return false, "no_mapping"
  end
  
  logNAT(string.format("IN: %s:%d -> %s:%d", 
    config.external_ip, destPort, natEntry.ip, natEntry.port))
  
  -- Подменяем DST на внутренний IP
  parsed.dst = natEntry.ip
  
  -- Подменяем порт обратно
  if parsed.isPayloadTable and type(parsed.payload) == "table" then
    parsed.payload.app_port = natEntry.port
  end
  
  -- Обновляем timestamp
  natEntry.ts = computer.uptime()
  
  return true
end

-- === DHCP ОБРАБОТЧИКИ ===

function Router.handleDHCPHello(senderMAC, senderIP)
  if leases[senderMAC] then
    local existingIP = leases[senderMAC].ip
    logDHCP(string.format("HELLO from %s -> Renewing %s", 
      senderMAC:sub(1, 8), existingIP))

    DHCP.renewLease(senderMAC, leases, tonumber(config.lease_timeout))
    Router.saveLeases()

    local ack = OCNP.createPacket(
      config.router_ip,
      senderMAC,
      OCNP.TYPE.DATA,
      {type = DHCP.MSG.ACK, ip = existingIP, router = config.router_ip},
      0
    )
    
    modem.send(senderMAC, Router.PORT, ack)
    logSuccess(string.format("Sent ACK with IP %s to %s", existingIP, senderMAC:sub(1, 8)))
    return
  end

  local newIP = DHCP.allocIP(config.pool_start, config.pool_end, leases)
  if not newIP then
    logError(string.format("DHCP HELLO from %s -> POOL EXHAUSTED!", senderMAC:sub(1, 8)))

    local nak = OCNP.createPacket(
      config.router_ip,
      senderMAC,
      OCNP.TYPE.DATA,
      {type = DHCP.MSG.NAK, reason = "No available IPs"},
      0
    )
    modem.send(senderMAC, Router.PORT, nak)
    return
  end

  leases[senderMAC] = DHCP.createLease(senderMAC, newIP, tonumber(config.lease_timeout))
  Router.saveLeases()

  logDHCP(string.format("HELLO from %s -> Allocated NEW IP: %s", 
    senderMAC:sub(1, 8), newIP))

  local ack = OCNP.createPacket(
    config.router_ip,
    senderMAC,
    OCNP.TYPE.DATA,
    {type = DHCP.MSG.ACK, ip = newIP, router = config.router_ip},
    0
  )
  modem.send(senderMAC, Router.PORT, ack)
  logSuccess(string.format("Sent ACK with IP %s to %s", newIP, senderMAC:sub(1, 8)))
end

function Router.handleDHCPRelease(senderMAC, senderIP)
  if leases[senderMAC] then
    local ip = leases[senderMAC].ip
    leases[senderMAC] = nil
    Router.saveLeases()
    logDHCP(string.format("RELEASE from %s -> IP %s freed", 
      senderMAC:sub(1, 8), ip))
  else
    logWarning(string.format("RELEASE from %s -> No lease found", senderMAC:sub(1, 8)))
  end
end

-- === HUB ФУНКЦИИ ===

function Router.registerWithHub()
  if config.hub_enabled ~= "true" or not config.hub_address or config.hub_address == "" then
    return
  end

  logHub("Registering with hub at " .. config.hub_address:sub(1, 8) .. "...")

  local packet = OCNP.createPacket(
    config.interface,
    "broadcast",
    OCNP.TYPE.DATA,
    {
      type = Router.HUB.HELLO,
      router_ip = config.router_ip
    },
    0
  )

  modem.send(config.hub_address, Router.HUB_PORT, packet)
  logHub("Registration packet sent (local IP: " .. config.router_ip .. ")")
end

function Router.handleHubACK(payload)
  if type(payload) ~= "table" then return end

  if payload.type == Router.HUB.ACK then
    if payload.ip and payload.ip ~= "" then
      config.external_ip = payload.ip
      logSuccess("Hub assigned external IP: " .. payload.ip)
      Utils.saveConfig(Router.CONFIG_PATH, config)
    else
      logWarning("Hub ACK received but no IP provided")
    end
  elseif payload.type == Router.HUB.NAK then
    logError("Hub registration FAILED: " .. (payload.reason or "unknown"))
  end
end

-- === ГЛАВНАЯ ФУНКЦИЯ МАРШРУТИЗАЦИИ ===

function Router.routePacket(rawPacket, senderMAC)
  -- Игнорируем свои пакеты
  if senderMAC == config.interface then
    return
  end

  -- ШАГ 1: Парсим пакет
  local parsed, err = OCNP.parsePacket(rawPacket)
  if not parsed then
    logError("Invalid packet dropped: " .. (err or "unknown"))
    return
  end

  -- ШАГ 2: Проверка версии
  if parsed.version ~= OCNP.VERSION then
    logWarning(string.format("Wrong protocol version: %s (expected %s)", 
      parsed.version, OCNP.VERSION))
    return
  end

  -- ШАГ 3: Проверка дубликатов
  if seenCache:has(parsed.uid) then
    logDebug("Duplicate packet ignored (UID: " .. parsed.uid:sub(1, 8) .. ")")
    return
  end
  seenCache:set(parsed.uid, {ts = computer.uptime()})

  -- ШАГ 4: Обработка служебных сообщений (DHCP, HUB)
  if parsed.isPayloadTable and type(parsed.payload) == "table" then
    local ptype = parsed.payload.type
    
    if ptype == DHCP.MSG.HELLO then
      Router.handleDHCPHello(senderMAC, parsed.src)
      return
    elseif ptype == DHCP.MSG.RELEASE then
      Router.handleDHCPRelease(senderMAC, parsed.src)
      return
    elseif ptype == Router.HUB.ACK or ptype == Router.HUB.NAK then
      Router.handleHubACK(parsed.payload)
      return
    end
  end

  -- ШАГ 5: Проверка TTL
  if parsed.ttl <= 0 then
    logWarning(string.format("TTL EXPIRED: %s -> %s (dropped)", 
      parsed.src, parsed.dst))
    return
  end

  -- ШАГ 6: Определяем направление
  local srcIsLocal = Router.isLocalIP(parsed.src)
  local dstIsLocal = Router.isLocalIP(parsed.dst)
  local dstIsOurExternal = (parsed.dst == config.external_ip)

  -- === ЛОКАЛЬНАЯ МАРШРУТИЗАЦИЯ ===
  if srcIsLocal and dstIsLocal then
    local targetMAC = Router.getMACByIP(parsed.dst)
    
    if not targetMAC then
      logWarning(string.format("LOCAL: %s -> %s: Destination unknown", 
        parsed.src, parsed.dst))
      return
    end
    
    if targetMAC == senderMAC then
      logDebug("Packet from sender to itself, ignoring")
      return
    end
    
    -- Декремент TTL (in-place)
    local result, err = OCNP.decrementTTL(parsed)
    if not result then
      logWarning("TTL decrement failed: " .. (err or "unknown"))
      return
    end
    
    -- Сериализуем и отправляем
    local finalPacket = OCNP.serialize(parsed)
    modem.send(targetMAC, Router.PORT, finalPacket)
    
    logRoute(string.format("LOCAL: %s -> %s via %s", 
      parsed.src, parsed.dst, targetMAC:sub(1, 8)))
    return
  end

  -- === ИСХОДЯЩИЙ (Local -> External) ===
  if srcIsLocal and not dstIsLocal then
    if config.hub_enabled ~= "true" or not config.hub_address or config.hub_address == "" then
      logWarning("Cannot route external packet: Hub disabled")
      return
    end
    
    -- Применяем NAT
    local natOK = Router.processNAT_Out(parsed, senderMAC)
    if not natOK then
      logError("NAT OUT failed")
      return
    end
    
    -- Декремент TTL
    local result, err = OCNP.decrementTTL(parsed)
    if not result then
      logWarning("TTL decrement failed: " .. (err or "unknown"))
      return
    end
    
    -- Сериализуем и отправляем на hub
    local finalPacket = OCNP.serialize(parsed)
    modem.send(config.hub_address, Router.HUB_PORT, finalPacket)
    
    logRoute(string.format("OUT: %s -> %s via HUB (NAT)", 
      parsed.src, parsed.dst))
    return
  end

  -- === ВХОДЯЩИЙ (External -> Local) ===
  if not srcIsLocal and dstIsLocal then
    local targetMAC = Router.getMACByIP(parsed.dst)
    
    if not targetMAC then
      logWarning(string.format("IN: %s -> %s: Local destination unknown", 
        parsed.src, parsed.dst))
      return
    end
    
    -- Декремент TTL
    local result, err = OCNP.decrementTTL(parsed)
    if not result then
      logWarning("TTL decrement failed: " .. (err or "unknown"))
      return
    end
    
    -- Сериализуем и отправляем
    local finalPacket = OCNP.serialize(parsed)
    modem.send(targetMAC, Router.PORT, finalPacket)
    
    logRoute(string.format("IN: %s -> %s via %s", 
      parsed.src, parsed.dst, targetMAC:sub(1, 8)))
    return
  end

  -- === ВХОДЯЩИЙ НА НАШ EXTERNAL IP (нужен обратный NAT) ===
  if not srcIsLocal and dstIsOurExternal then
    local natOK, natErr = Router.processNAT_In(parsed)
    if not natOK then
      if natErr ~= "not_our_ip" then
        logWarning("NAT IN failed: " .. (natErr or "unknown"))
      end
      return
    end
    
    -- После NAT dst изменился на локальный IP
    local targetMAC = Router.getMACByIP(parsed.dst)
    if not targetMAC then
      logWarning(string.format("NAT IN: %s not found after NAT", parsed.dst))
      return
    end
    
    -- Декремент TTL
    local result, err = OCNP.decrementTTL(parsed)
    if not result then
      logWarning("TTL decrement failed: " .. (err or "unknown"))
      return
    end
    
    -- Сериализуем и отправляем
    local finalPacket = OCNP.serialize(parsed)
    modem.send(targetMAC, Router.PORT, finalPacket)
    
    logRoute(string.format("NAT IN: %s -> %s via %s", 
      parsed.src, parsed.dst, targetMAC:sub(1, 8)))
    return
  end

  -- === ТРАНЗИТ (External -> External, но не наш IP) ===
  if not srcIsLocal and not dstIsLocal and not dstIsOurExternal then
    if config.hub_enabled ~= "true" then
      logWarning("Transit packet dropped: Hub disabled")
      return
    end
    
    -- Декремент TTL
    local result, err = OCNP.decrementTTL(parsed)
    if not result then
      logWarning("TTL decrement failed: " .. (err or "unknown"))
      return
    end
    
    -- Сериализуем и отправляем на hub
    local finalPacket = OCNP.serialize(parsed)
    modem.send(config.hub_address, Router.HUB_PORT, finalPacket)
    
    logRoute(string.format("TRANSIT: %s -> %s via HUB", 
      parsed.src, parsed.dst))
    return
  end
end

-- === ЗАПУСК ===

function Router.start()
  term.clear()
  
  gpu.setForeground(0x00FFFF)
  print("╔════════════════════════════════════════╗")
  print("║   PetusRouter v" .. Router.VERSION .. " - NAT Ready    ║")
  print("╚════════════════════════════════════════╝")
  gpu.setForeground(0xFFFFFF)
  print("")

  logInfo("Initializing router...")

  Router.loadConfig()
  Router.loadLeases()

  seenCache = Utils.LRUCache.new(2000)

  logInfo("Configuration:")
  logInfo("  Interface: " .. config.interface:sub(1, 16) .. "...")
  logInfo("  Router IP: " .. config.router_ip)
  logInfo("  Subnet: " .. config.subnet .. "/" .. config.mask)
  logInfo("  DHCP Pool: " .. config.pool_start .. " - " .. config.pool_end)

  if config.hub_enabled == "true" then
    logHub("Hub Status: ENABLED")
    if config.hub_address and config.hub_address ~= "" then
      logHub("  Hub Address: " .. config.hub_address:sub(1, 16) .. "...")
    end
    if config.external_ip and config.external_ip ~= "" then
      logHub("  External IP: " .. config.external_ip)
    else
      logHub("  External IP: will be assigned by ISP")
    end
  else
    logInfo("Hub Status: DISABLED")
  end

  local leaseCount = Utils.tableSize(leases)
  logInfo("Active Leases: " .. leaseCount)

  modem = component.proxy(config.interface)
  if not modem then
    logError("FATAL: Interface not found!")
    return
  end

  modem.open(Router.PORT)
  modem.open(Router.HUB_PORT)
  logSuccess("Listening on port " .. Router.PORT .. " (local)")
  logSuccess("Listening on port " .. Router.HUB_PORT .. " (hub)")
  
  print("")
  gpu.setForeground(0x00FF00)
  print("✓ Router is READY!")
  gpu.setForeground(0xFFFFFF)
  print("═══════════════════════════════════════════")
  print("")

  if config.hub_enabled == "true" then
    Router.registerWithHub()
  end

  -- Главный цикл
  while true do
    local eventData = {event.pull(1, "modem_message")}
    
    if eventData[1] == "modem_message" then
      local localAddress = eventData[2]
      local remoteAddress = eventData[3]
      local port = eventData[4]
      local distance = eventData[5]
      local packet = eventData[6]

      packetCounter = packetCounter + 1

      -- Периодическая очистка
      if packetCounter % Router.CLEANUP_INTERVAL == 0 then
        logDebug("Running cleanup...")
        seenCache:cleanup(Router.SEEN_TTL)
        DHCP.cleanupExpiredLeases(leases, tonumber(config.lease_timeout))
        Router.cleanupNAT()
      end

      if port == Router.PORT or port == Router.HUB_PORT then
        Router.routePacket(packet, remoteAddress)
      end
    end
  end
end

Router.start()
