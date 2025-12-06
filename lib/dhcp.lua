local computer = require("computer")
local filesystem = require("filesystem")
local serialization = require("serialization")

local DHCP = {}

DHCP.MSG = {
  HELLO = "DHCP_HELLO",
  RELEASE = "DHCP_RELEASE",
  ACK = "DHCP_ACK",
  NAK = "DHCP_NAK"
}

DHCP.DEFAULT_LEASE_TIME = 3600

function DHCP.createLease(mac, ip, leaseTime)
  return {
    mac = mac,
    ip = ip,
    ts = computer.uptime(),
    leaseTime = leaseTime or DHCP.DEFAULT_LEASE_TIME
  }
end

function DHCP.isLeaseExpired(lease, now)
  now = now or computer.uptime()
  return (now - lease.ts) > lease.leaseTime
end

function DHCP.parseIP(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

function DHCP.ipToNumber(ip)
  local a, b, c, d = DHCP.parseIP(ip)
  if not a then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

function DHCP.numberToIP(num)
  local d = num % 256
  num = math.floor(num / 256)
  local c = num % 256
  num = math.floor(num / 256)
  local b = num % 256
  local a = math.floor(num / 256)
  return string.format("%d.%d.%d.%d", a, b, c, d)
end

function DHCP.allocIP(poolStart, poolEnd, leases)
  local startNum = DHCP.ipToNumber(poolStart)
  local endNum = DHCP.ipToNumber(poolEnd)
  
  if not startNum or not endNum then
    return nil
  end
  
  local usedIPs = {}
  for mac, lease in pairs(leases) do
    if lease.ip then
      usedIPs[lease.ip] = true
    end
  end
  
  for i = startNum, endNum do
    local ip = DHCP.numberToIP(i)
    if not usedIPs[ip] then
      return ip
    end
  end
  
  return nil
end

function DHCP.releaseIP(mac, leases)
  if leases[mac] then
    local ip = leases[mac].ip
    leases[mac] = nil
    return ip
  end
  return nil
end

function DHCP.cleanupExpiredLeases(leases, leaseTimeout)
  local now = computer.uptime()
  local removed = {}
  
  for mac, lease in pairs(leases) do
    if DHCP.isLeaseExpired(lease, now) then
      table.insert(removed, mac)
    end
  end
  
  for _, mac in ipairs(removed) do
    leases[mac] = nil
  end
  
  return #removed
end

function DHCP.persistLeases(path, leases)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then
    filesystem.makeDirectory(dir)
  end
  
  local file, err = io.open(path, "w")
  if not file then 
    print("[DHCP ERROR] Cannot open file: " .. tostring(err))
    return false 
  end
  
  for mac, lease in pairs(leases) do
    local safeMac = tostring(mac or "unknown")
    local safeIP = tostring(lease.ip or "0.0.0.0")
    local safeTS = tonumber(lease.ts) or 0
    local safeLeaseTime = tonumber(lease.leaseTime) or 3600
    
    -- ИСПОЛЬЗУЕМ %f ВМЕСТО %d ДЛЯ FLOAT!!!
    local success, err = pcall(function()
      file:write(string.format("%s:%s:%f:%d\n", safeMac, safeIP, safeTS, safeLeaseTime))
    end)
    
    if not success then
      print("[DHCP ERROR] Failed to write lease: " .. tostring(err))
      print("  MAC: " .. safeMac)
      print("  IP: " .. safeIP)
      print("  TS: " .. tostring(safeTS))
      print("  LeaseTime: " .. tostring(safeLeaseTime))
    end
  end
  
  file:close()
  return true
end

function DHCP.loadLeases(path)
  if not filesystem.exists(path) then
    return {}
  end
  
  local file = io.open(path, "r")
  if not file then return {} end
  
  local leases = {}
  for line in file:lines() do
    local mac, ip, ts, leaseTime = line:match("^([^:]+):([^:]+):(%d+):(%d+)$")
    if mac and ip then
      leases[mac] = {
        mac = mac,
        ip = ip,
        ts = tonumber(ts) or 0,
        leaseTime = tonumber(leaseTime) or DHCP.DEFAULT_LEASE_TIME
      }
    end
  end
  
  file:close()
  return leases
end

function DHCP.renewLease(mac, leases, leaseTime)
  if leases[mac] then
    leases[mac].ts = computer.uptime()
    leases[mac].leaseTime = leaseTime or leases[mac].leaseTime
    return true
  end
  return false
end

function DHCP.getLeaseByIP(ip, leases)
  for mac, lease in pairs(leases) do
    if lease.ip == ip then
      return lease
    end
  end
  return nil
end

function DHCP.getLeaseByMAC(mac, leases)
  return leases[mac]
end

return DHCP
