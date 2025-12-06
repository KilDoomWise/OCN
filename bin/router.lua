local component = require("component")
local event = require("event")
local computer = require("computer")
local filesystem = require("filesystem")
local term = require("term")

-- Убедитесь, что эти библиотеки существуют
local OCNP = require("ocnp")
local Utils = require("utils")
local DHCP = require("dhcp")

local Router = {}
Router.VERSION = "1.1"
Router.PORT = 31
Router.HUB_PORT = 32
Router.CONFIG_PATH = "/etc/PetusRouter/conf.oc"
Router.ROUTES_PATH = "/etc/PetusRouter/routes.db"
Router.CLEANUP_INTERVAL = 100
Router.SEEN_TTL = 30

Router.HUB = {
  HELLO = "HUB_ROUTER_HELLO",
  ACK = "HUB_ROUTER_ACK",
  NAK = "HUB_ROUTER_NAK"
}

-- === ЦВЕТНАЯ СИСТЕМА ЛОГИРОВАНИЯ ===
local gpu = component.gpu
local LOG_COLORS = {
  ERROR = 0xFF0000,    -- Красный
  WARNING = 0xFFAA00,  -- Оранжевый
  SUCCESS = 0x00FF00,  -- Зеленый
  INFO = 0x00AAFF,     -- Голубой
  DEBUG = 0xAAAAAA,    -- Серый
  DHCP = 0xFF00FF,     -- Фиолетовый
  ROUTE = 0xFFFF00,    -- Желтый
  HUB = 0x00FFFF       -- Циан
}

local function colorLog(category, message, color)
  local timestamp = string.format("[%.2f]", computer.uptime())
  local prefix = string.format("[%s]", category)
  
  -- Сохраняем текущие цвета
  local oldBg = gpu.getBackground()
  local oldFg = gpu.getForeground()
  
  -- Timestamp белым
  gpu.setForeground(0xFFFFFF)
  term.write(timestamp .. " ")
  
  -- Категория цветная
  gpu.setForeground(color)
  term.write(prefix .. " ")
  
  -- Сообщение белым
  gpu.setForeground(0xFFFFFF)
  print(message)
  
  -- Восстанавливаем цвета
  gpu.setBackground(oldBg)
  gpu.setForeground(oldFg)
end

local function logError(msg)
  colorLog("ERROR", msg, LOG_COLORS.ERROR)
end

local function logWarning(msg)
  colorLog("WARN", msg, LOG_COLORS.WARNING)
end

local function logSuccess(msg)
  colorLog("OK", msg, LOG_COLORS.SUCCESS)
end

local function logInfo(msg)
  colorLog("INFO", msg, LOG_COLORS.INFO)
end

local function logDebug(msg)
  colorLog("DEBUG", msg, LOG_COLORS.DEBUG)
end

local function logDHCP(msg)
  colorLog("DHCP", msg, LOG_COLORS.DHCP)
end

local function logRoute(msg)
  colorLog("ROUTE", msg, LOG_COLORS.ROUTE)
end

local function logHub(msg)
  colorLog("HUB", msg, LOG_COLORS.HUB)
end

-- Красивый вывод содержимого пакета
local function logPacketContent(parsed, incoming)
  local direction = incoming and "<<< INCOMING >>>" or ">>> OUTGOING >>>"
  local color = incoming and LOG_COLORS.INFO or LOG_COLORS.DEBUG
  
  colorLog("PACKET", direction, color)
  logDebug(string.format("  Type: %s | SRC: %s | DST: %s", 
    parsed.type or "?", 
    parsed.src and parsed.src:sub(1, 12) or "?",
    parsed.dst and parsed.dst:sub(1, 12) or "?"))
  logDebug(string.format("  SEQ: %d | UID: %s | TTL: %d", 
    parsed.seq or 0, 
    parsed.uid and parsed.uid:sub(1, 8) or "?",
    parsed.ttl or 0))
  
  if type(parsed.payload) == "table" then
    logDebug("  Payload: {")
    for k, v in pairs(parsed.payload) do
      logDebug(string.format("    %s = %s", tostring(k), tostring(v)))
    end
    logDebug("  }")
  elseif parsed.payload and parsed.payload ~= "" then
    local preview = tostring(parsed.payload):sub(1, 60)
    if #tostring(parsed.payload) > 60 then preview = preview .. "..." end
    logDebug("  Payload: " .. preview)
  end
end

-- === ОСНОВНОЙ КОД РОУТЕРА ===

local config = {}
local leases = {}
local seenCache = nil
local modem = nil
local packetCounter = 0

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

  -- ОТЛАДКА
  logDebug("=== LEASE DEBUG ===")
  logDebug("  MAC: " .. tostring(senderMAC))
  logDebug("  IP: " .. tostring(newIP))
  if leases[senderMAC] then
    logDebug("  Lease.ip: " .. tostring(leases[senderMAC].ip))
    logDebug("  Lease.ts: " .. tostring(leases[senderMAC].ts))
    logDebug("  Lease.leaseTime: " .. tostring(leases[senderMAC].leaseTime))
  else
    logError("LEASE IS NIL!")
  end

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
      router_ip = config.router_ip,       
      external_ip = config.external_ip    
    },
    0
  )

  modem.send(config.hub_address, Router.HUB_PORT, packet)
  logHub("Registration packet sent")
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

function Router.routePacket(packet, senderMAC)
  -- === ПРОВЕРКА 1: Игнорируем свои собственные пакеты ===
  if senderMAC == config.interface then
    logDebug("Ignoring own packet from " .. senderMAC:sub(1, 8))
    return
  end

  -- === ПРОВЕРКА 2: Парсинг пакета ===
  local parsed, err = OCNP.parsePacket(packet)
  if not parsed then
    logError("Invalid packet dropped: " .. (err or "unknown"))
    logDebug("  From MAC: " .. senderMAC:sub(1, 8))
    logDebug("  Packet length: " .. #packet)
    logDebug("  First 100 chars: " .. packet:sub(1, 100))
    return
  end

  -- === ПРОВЕРКА 3: Версия протокола ===
  if parsed.version ~= OCNP.VERSION then
    logWarning(string.format("Wrong protocol version: %s (expected %s)", 
      parsed.version, OCNP.VERSION))
    return
  end

  -- -- === ПРОВЕРКА 4: Дубликаты (UID Cache) ===
  -- if seenCache:has(parsed.uid) then
  --   logDebug("Duplicate packet ignored (UID: " .. parsed.uid:sub(1, 8) .. ")")
  --   return
  -- end

  seenCache:set(parsed.uid, {ts = computer.uptime()})

  -- === ЛОГИРОВАНИЕ ВХОДЯЩЕГО ПАКЕТА ===
  logPacketContent(parsed, true)

  -- === ОБРАБОТКА DHCP ===
  if parsed.type == OCNP.TYPE.DATA and type(parsed.payload) == "table" then
    if parsed.payload.type == DHCP.MSG.HELLO then
      Router.handleDHCPHello(senderMAC, parsed.src)
      return
    elseif parsed.payload.type == DHCP.MSG.RELEASE then
      Router.handleDHCPRelease(senderMAC, parsed.src)
      return
    elseif parsed.payload.type == Router.HUB.ACK or parsed.payload.type == Router.HUB.NAK then
      Router.handleHubACK(parsed.payload)
      return
    end
  end

  -- === ПРОВЕРКА 5: TTL ===
  if parsed.ttl <= 0 then
    logWarning(string.format("TTL EXPIRED: %s -> %s (dropped)", 
      parsed.src, parsed.dst))

    local errorPkt = OCNP.createError(
      config.router_ip,
      parsed.src,
      "TTL_EXPIRED",
      "TTL reached zero",
      {original_uid = parsed.uid}
    )
    modem.broadcast(Router.PORT, errorPkt)
    return
  end

  -- === МАРШРУТИЗАЦИЯ ===
  if Router.isLocalIP(parsed.dst) then
    -- Локальная маршрутизация
    local targetMAC = Router.getMACByIP(parsed.dst)
    if not targetMAC then
      logWarning(string.format("ROUTE %s -> %s: Destination UNKNOWN", 
        parsed.src, parsed.dst))
      return
    end

    if targetMAC == senderMAC then
      logDebug("Packet from sender to itself, ignoring")
      return
    end

    logRoute(string.format("LOCAL: %s -> %s via MAC %s", 
      parsed.src, parsed.dst, targetMAC:sub(1, 8)))

    local newPacket, err = OCNP.decrementTTL(parsed)
    if not newPacket then
      logError("Failed to decrement TTL: " .. (err or "unknown"))
      return
    end

    modem.send(targetMAC, Router.PORT, newPacket)
    logSuccess(string.format("Forwarded to %s (TTL: %d -> %d)", 
      targetMAC:sub(1, 8), parsed.ttl, parsed.ttl - 1))
  else
    -- Внешняя маршрутизация через Hub
    if config.hub_enabled ~= "true" then
      logWarning(string.format("ROUTE %s -> %s: Hub DISABLED, dropped", 
        parsed.src, parsed.dst))
      return
    end

    if not config.hub_address or config.hub_address == "" then
      logWarning(string.format("ROUTE %s -> %s: No Hub connection, dropped", 
        parsed.src, parsed.dst))
      return
    end

    logRoute(string.format("EXTERNAL: %s -> %s via HUB", 
      parsed.src, parsed.dst))

    local newPacket, err = OCNP.decrementTTL(parsed)
    if not newPacket then
      logError("Failed to decrement TTL: " .. (err or "unknown"))
      return
    end

    modem.send(config.hub_address, Router.HUB_PORT, newPacket)
    logSuccess(string.format("Forwarded to HUB (TTL: %d -> %d)", 
      parsed.ttl, parsed.ttl - 1))
  end
end

function Router.start()
  term.clear()
  
  -- === ЗАГОЛОВОК ===
  gpu.setForeground(0x00FFFF)
  print("╔════════════════════════════════════════╗")
  print("║     PetusRouter v" .. Router.VERSION .. " - Enhanced    ║")
  print("╚════════════════════════════════════════╝")
  gpu.setForeground(0xFFFFFF)
  print("")

  logInfo("Initializing router...")

  Router.loadConfig()
  Router.loadLeases()

  seenCache = Utils.LRUCache.new(2000)

  -- === КОНФИГУРАЦИЯ ===
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
    end
  else
    logInfo("Hub Status: DISABLED")
  end

  local leaseCount = 0
  for _ in pairs(leases) do
    leaseCount = leaseCount + 1
  end
  logInfo("Active Leases: " .. leaseCount)

  -- === ИНИЦИАЛИЗАЦИЯ МОДЕМА ===
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
  print("✓ Router is READY and ONLINE!")
  gpu.setForeground(0xFFFFFF)
  print("═══════════════════════════════════════════")
  print("")

  if config.hub_enabled == "true" then
    Router.registerWithHub()
  end

  -- === ГЛАВНЫЙ ЦИКЛ ===
  while true do
    local eventData = {event.pull("modem_message")}
    if eventData[1] == "modem_message" then
      local localAddress = eventData[2]
      local remoteAddress = eventData[3]
      local port = eventData[4]
      local distance = eventData[5]
      local packet = eventData[6]

      packetCounter = packetCounter + 1

      -- Периодическая очистка
      if packetCounter % Router.CLEANUP_INTERVAL == 0 then
        logDebug("Running cleanup (cache + expired leases)...")
        seenCache:cleanup(Router.SEEN_TTL)
        DHCP.cleanupExpiredLeases(leases, tonumber(config.lease_timeout))
      end

      if port == Router.PORT or port == Router.HUB_PORT then
        Router.routePacket(packet, remoteAddress)
      end
    end
  end
end

Router.start()
