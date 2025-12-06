-- ISP (fixed)
local component = require("component")
local event = require("event")
local computer = require("computer")
local filesystem = require("filesystem")

local OCNP = require("ocnp")
local Utils = require("utils")
local DHCP = require("dhcp")
local BGP = require("bgp")

local ISP = {}
ISP.VERSION = "1.1"
ISP.HUB_PORT = 32
ISP.IX_PORT = 33
ISP.CONFIG_PATH = "/etc/PetusISP/isp.conf"
ISP.ROUTES_PATH = "/etc/PetusISP/routes.db"
ISP.WAL_PATH = "/etc/PetusISP/wal.log"
ISP.CLEANUP_INTERVAL = 100
ISP.SEEN_TTL = 30
ISP.SNAPSHOT_INTERVAL = 200
ISP.HEARTBEAT_INTERVAL = 30

local config = {}
local routingTable = {}
local clients = {}
local seenCache = nil
local modem = nil
local packetCounter = 0
local walCounter = 0
local orsSeq = 0
local lastHeartbeat = 0

function ISP.loadConfig()
  config = Utils.loadConfig(ISP.CONFIG_PATH)

  if not config.interface then
    config.interface = component.modem.address
    config.provider_id = "ISP_DEFAULT"
    config.external_ip = "10.10.10.1"
    config.subnets = "10.10.10.0/24"
    config.peers = ""
    config.ix_nodes = ""
    Utils.saveConfig(ISP.CONFIG_PATH, config)
  end

  return config
end

function ISP.loadRoutingTable()
  routingTable = Utils.loadTable(ISP.ROUTES_PATH)
  return routingTable
end

function ISP.saveRoutingTable()
  Utils.saveTable(ISP.ROUTES_PATH, routingTable)
end

function ISP.writeWAL(operation, data)
  local line = string.format("%s %s %s",
    operation,
    data.prefix or "",
    data.next_hop or "")
  Utils.appendToFile(ISP.WAL_PATH, line)
  walCounter = walCounter + 1

  if walCounter >= ISP.SNAPSHOT_INTERVAL then
    ISP.saveRoutingTable()
    walCounter = 0
  end
end

function ISP.getPeers()
  if not config.peers or config.peers == "" then
    return {}
  end

  local peers = {}
  for peer in config.peers:gmatch("[^,]+") do
    table.insert(peers, peer)
  end
  return peers
end

function ISP.getIXNodes()
  if not config.ix_nodes or config.ix_nodes == "" then
    return {}
  end

  local nodes = {}
  for node in config.ix_nodes:gmatch("[^,]+") do
    table.insert(nodes, node)
  end
  return nodes
end

function ISP.getOwnSubnets()
  if not config.subnets or config.subnets == "" then
    return {}
  end

  local subnets = {}
  for subnet in config.subnets:gmatch("[^,]+") do
    table.insert(subnets, subnet)
  end
  return subnets
end

function ISP.isOwnSubnet(ip)
  for _, subnetStr in ipairs(ISP.getOwnSubnets()) do
    local subnet, maskStr = subnetStr:match("^([^/]+)/(%d+)$")
    if subnet and maskStr then
      if Utils.inSubnet(ip, subnet, tonumber(maskStr)) then
        return true
      end
    end
  end
  return false
end

function ISP.announceOwnSubnets()
  local subnets = ISP.getOwnSubnets()
  local peers = ISP.getPeers()
  local ixNodes = ISP.getIXNodes()

  for _, subnetStr in ipairs(subnets) do
    local subnet, maskStr = subnetStr:match("^([^/]+)/(%d+)$")
    if subnet and maskStr then
      orsSeq = orsSeq + 1
      local announce = BGP.createAnnounce(
        subnet,
        tonumber(maskStr),
        config.provider_id,
        config.external_ip,
        1,
        orsSeq
      )

      local packet = OCNP.createPacket(
        config.external_ip,
        "broadcast",
        OCNP.TYPE.ORS,
        announce,
        orsSeq
      )

      for _, peer in ipairs(peers) do
        modem.send(peer, config.interface, ISP.HUB_PORT, packet)
      end

      for _, ix in ipairs(ixNodes) do
        modem.send(ix, config.interface, ISP.IX_PORT, packet)
      end

      Utils.log("ISP", string.format("Announced %s/%s to peers/IX", subnet, maskStr))
    end
  end
end

function ISP.handleORS(parsed)
  if parsed.type ~= OCNP.TYPE.ORS then
    return
  end

  local ors = parsed.payload
  if type(ors) ~= "table" then
    return
  end

  local success, err = BGP.updateRoutingTable(routingTable, ors)
  if success then
    ISP.writeWAL("UPDATE_ROUTE", {
      prefix = BGP.prefixKey(ors.prefix, ors.mask),
      next_hop = ors.next_hop
    })

    Utils.log("ISP", string.format("ORS %s: %s/%d via %s (origin: %s)",
      ors.action, ors.prefix, ors.mask, ors.next_hop or "withdrawn", ors.origin))
  else
    Utils.log("ISP", string.format("ORS update failed: %s", err or "unknown"))
  end
end

function ISP.registerClient(clientMAC, clientIP)
  clients[clientMAC] = {
    ip = clientIP,
    ts = computer.uptime()
  }

  Utils.log("ISP", string.format("Client registered: %s -> %s",
    clientMAC:sub(1, 8), clientIP))
end

function ISP.handleRouterHello(parsed, senderMAC)
  if parsed.type ~= OCNP.TYPE.DATA then
    return
  end

  local payload = parsed.payload
  if type(payload) ~= "table" or payload.type ~= "HUB_ROUTER_HELLO" then
    return
  end

  -- prefer external_ip if router provided it; fallback to router_ip
  local routerIP = payload.external_ip or payload.router_ip
  if not routerIP or routerIP == "" then
    Utils.log("ISP", string.format("Router hello from %s missing ip fields", senderMAC:sub(1,8)))
    return
  end

  if ISP.isOwnSubnet(routerIP) then
    ISP.registerClient(senderMAC, routerIP)

    -- reply with standard HUB ACK
    local ack = OCNP.createPacket(
      config.external_ip,
      senderMAC,
      OCNP.TYPE.DATA,
      {type = "HUB_ROUTER_ACK", ip = config.external_ip},
      0
    )
    modem.send(senderMAC, config.interface, ISP.HUB_PORT, ack)

    Utils.log("ISP", string.format("Router hello ACK sent to %s (registered %s)", senderMAC:sub(1, 8), routerIP))
  else
    local nak = OCNP.createPacket(
      config.external_ip,
      senderMAC,
      OCNP.TYPE.DATA,
      {type = "HUB_ROUTER_NAK", reason = "Not in our subnet"},
      0
    )
    modem.send(senderMAC, config.interface, ISP.HUB_PORT, nak)

    Utils.log("ISP", string.format("Router hello NAK sent to %s (wrong subnet: %s)", senderMAC:sub(1, 8), routerIP))
  end
end

function ISP.routePacket(packet, senderMAC, port)
  local parsed, err = OCNP.parsePacket(packet)
  if not parsed then
    Utils.log("ISP", "Invalid packet dropped: " .. (err or "unknown"))
    return
  end

  if parsed.version ~= ISP.VERSION then
    Utils.log("ISP", "Unknown packet version, dropped")
    return
  end

  if seenCache:has(parsed.uid) then
    return
  end

  seenCache:set(parsed.uid, {ts = computer.uptime()})

  if parsed.type == OCNP.TYPE.ORS then
    ISP.handleORS(parsed)
    return
  end

  if parsed.type == OCNP.TYPE.DATA and type(parsed.payload) == "table" then
    if parsed.payload.type == "HUB_ROUTER_HELLO" then
      ISP.handleRouterHello(parsed, senderMAC)
      return
    end
  end

  if parsed.ttl <= 0 then
    Utils.log("ISP", string.format("TTL expired %s -> %s (dropped)",
      parsed.src, parsed.dst))

    local errorPkt = OCNP.createError(
      config.external_ip,
      parsed.src,
      "TTL_EXPIRED",
      "TTL reached zero",
      {original_uid = parsed.uid}
    )
    modem.broadcast(ISP.HUB_PORT, errorPkt)
    return
  end

  if ISP.isOwnSubnet(parsed.dst) then
    local targetMAC = nil
    for mac, client in pairs(clients) do
      if client.ip == parsed.dst then
        targetMAC = mac
        break
      end
    end

    if not targetMAC then
      Utils.log("ISP", string.format("ROUTE %s -> %s (client unknown)",
        parsed.src, parsed.dst))

      local errorPkt = OCNP.createError(
        config.external_ip,
        parsed.src,
        "UNREACHABLE",
        "Destination not found in our network",
        {dst = parsed.dst}
      )
      modem.broadcast(ISP.HUB_PORT, errorPkt)
      return
    end

    Utils.log("ISP", string.format("ROUTE %s -> %s via %s (local client)",
      parsed.src, parsed.dst, targetMAC:sub(1, 8)))

    local newPacket, err = OCNP.decrementTTL(parsed)
    if not newPacket then
      Utils.log("ISP", "Failed to decrement TTL: " .. (err or "unknown"))
      return
    end

    modem.send(targetMAC, config.interface, ISP.HUB_PORT, newPacket)
  else
    local route = BGP.lookupRoute(parsed.dst, routingTable)

    if not route then
      Utils.log("ISP", string.format("ROUTE %s -> %s (no route)",
        parsed.src, parsed.dst))

      local errorPkt = OCNP.createError(
        config.external_ip,
        parsed.src,
        "UNREACHABLE",
        "No route to destination",
        {dst = parsed.dst}
      )
      modem.broadcast(ISP.HUB_PORT, errorPkt)
      return
    end

    Utils.log("ISP", string.format("ROUTE %s -> %s via %s (next hop)",
      parsed.src, parsed.dst, route.next_hop))

    local newPacket, err = OCNP.decrementTTL(parsed)
    if not newPacket then
      Utils.log("ISP", "Failed to decrement TTL: " .. (err or "unknown"))
      return
    end

    modem.broadcast(ISP.HUB_PORT, newPacket)
  end
end

function ISP.sendHeartbeat()
  local now = computer.uptime()
  if now - lastHeartbeat < ISP.HEARTBEAT_INTERVAL then
    return
  end

  lastHeartbeat = now

  local peers = ISP.getPeers()
  for _, peer in ipairs(peers) do
    local ping = OCNP.createPacket(
      config.external_ip,
      peer,
      OCNP.TYPE.PING,
      "",
      0
    )
    modem.send(peer, config.interface, ISP.HUB_PORT, ping)
  end
end

function ISP.start()
  Utils.log("ISP", "ISP Node v" .. ISP.VERSION .. " starting...")

  ISP.loadConfig()
  ISP.loadRoutingTable()

  seenCache = Utils.LRUCache.new(2000)

  Utils.log("ISP", "Provider ID: " .. config.provider_id)
  Utils.log("ISP", "Interface: " .. config.interface:sub(1, 8))
  Utils.log("ISP", "External IP: " .. config.external_ip)
  Utils.log("ISP", "Subnets: " .. config.subnets)

  local peers = ISP.getPeers()
  if #peers > 0 then
    Utils.log("ISP", "Peers: " .. #peers)
  else
    Utils.log("ISP", "Peers: none configured")
  end

  local ixNodes = ISP.getIXNodes()
  if #ixNodes > 0 then
    Utils.log("ISP", "IX Nodes: " .. #ixNodes)
  else
    Utils.log("ISP", "IX Nodes: none configured")
  end

  local stats = BGP.getRoutingTableStats(routingTable)
  Utils.log("ISP", string.format("Loaded routing table: %d prefixes, %d routes",
    stats.prefixes, stats.routes))

  modem = component.proxy(config.interface)
  if not modem then
    Utils.log("ISP", "ERROR: Interface not found!")
    return
  end

  modem.open(ISP.HUB_PORT)
  modem.open(ISP.IX_PORT)
  Utils.log("ISP", "Listening on port " .. ISP.HUB_PORT .. " (hub)")
  Utils.log("ISP", "Listening on port " .. ISP.IX_PORT .. " (ix)")
  Utils.log("ISP", "ISP ready!")

  ISP.announceOwnSubnets()

  while true do
    local eventData = {event.pull(1, "modem_message")}

    if eventData[1] == "modem_message" then
      local localAddress = eventData[2]
      local remoteAddress = eventData[3]
      local port = eventData[4]
      local distance = eventData[5]
      local packet = eventData[6]

      packetCounter = packetCounter + 1

      if packetCounter % ISP.CLEANUP_INTERVAL == 0 then
        seenCache:cleanup(ISP.SEEN_TTL)
      end

      if port == ISP.HUB_PORT or port == ISP.IX_PORT then
        ISP.routePacket(packet, remoteAddress, port)
      end
    end

    ISP.sendHeartbeat()
  end
end

ISP.start()
