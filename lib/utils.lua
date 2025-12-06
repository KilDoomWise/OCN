local filesystem = require("filesystem")
local serialization = require("serialization")
local computer = require("computer")

local Utils = {}

function Utils.log(component, msg)
  local timestamp = string.format("[%.2f]", computer.uptime())
  print(timestamp .. " [" .. component .. "] " .. msg)
end

function Utils.parseIP(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

function Utils.ipToNumber(ip)
  local a, b, c, d = Utils.parseIP(ip)
  if not a then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

function Utils.numberToIP(num)
  local d = num % 256
  num = math.floor(num / 256)
  local c = num % 256
  num = math.floor(num / 256)
  local b = num % 256
  local a = math.floor(num / 256)
  return string.format("%d.%d.%d.%d", a, b, c, d)
end

function Utils.inSubnet(ip, subnet, mask)
  local ipNum = Utils.ipToNumber(ip)
  local subnetNum = Utils.ipToNumber(subnet)
  if not ipNum or not subnetNum then return false end
  
  local bits = mask or 24
  local shift = 32 - bits
  
  return math.floor(ipNum / (2 ^ shift)) == math.floor(subnetNum / (2 ^ shift))
end

function Utils.longestPrefixMatch(ip, routeTable)
  local ipNum = Utils.ipToNumber(ip)
  if not ipNum then return nil end
  
  local bestMatch = nil
  local bestMask = -1
  
  for prefix, route in pairs(routeTable) do
    local subnet, maskStr = prefix:match("^([^/]+)/(%d+)$")
    if subnet and maskStr then
      local mask = tonumber(maskStr)
      if Utils.inSubnet(ip, subnet, mask) then
        if mask > bestMask then
          bestMask = mask
          bestMatch = route
        end
      end
    end
  end
  
  return bestMatch
end

function Utils.saveTable(path, tbl)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then
    filesystem.makeDirectory(dir)
  end
  
  local file = io.open(path, "w")
  if not file then return false end
  
  file:write(serialization.serialize(tbl))
  file:close()
  return true
end

function Utils.loadTable(path)
  if not filesystem.exists(path) then
    return {}
  end
  
  local file = io.open(path, "r")
  if not file then return {} end
  
  local content = file:read("*a")
  file:close()
  
  if content == "" then return {} end
  
  local success, result = pcall(serialization.unserialize, content)
  if success then
    return result
  else
    return {}
  end
end

function Utils.appendToFile(path, line)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then
    filesystem.makeDirectory(dir)
  end
  
  local file = io.open(path, "a")
  if not file then return false end
  
  file:write(line .. "\n")
  file:close()
  return true
end

function Utils.loadConfig(path)
  if not filesystem.exists(path) then
    return {}
  end
  
  local file = io.open(path, "r")
  if not file then return {} end
  
  local config = {}
  for line in file:lines() do
    local key, value = line:match("^([^=]+)=(.+)$")
    if key and value then
      config[key] = value
    end
  end
  
  file:close()
  return config
end

function Utils.saveConfig(path, config)
  local dir = path:match("^(.+)/[^/]+$")
  if dir then
    filesystem.makeDirectory(dir)
  end
  
  local file = io.open(path, "w")
  if not file then return false end
  
  for key, value in pairs(config) do
    file:write(string.format("%s=%s\n", key, value))
  end
  
  file:close()
  return true
end

Utils.LRUCache = {}
Utils.LRUCache.__index = Utils.LRUCache

function Utils.LRUCache.new(capacity)
  local self = setmetatable({}, Utils.LRUCache)
  self.capacity = capacity or 2000
  self.cache = {}
  self.order = {}
  self.size = 0
  return self
end

function Utils.LRUCache:get(key)
  local value = self.cache[key]
  if value then
    self:_moveToFront(key)
    return value
  end
  return nil
end

function Utils.LRUCache:set(key, value)
  if self.cache[key] then
    self.cache[key] = value
    self:_moveToFront(key)
  else
    if self.size >= self.capacity then
      self:_evictOldest()
    end
    
    self.cache[key] = value
    table.insert(self.order, 1, key)
    self.size = self.size + 1
  end
end

function Utils.LRUCache:has(key)
  return self.cache[key] ~= nil
end

function Utils.LRUCache:remove(key)
  if not self.cache[key] then return end
  
  self.cache[key] = nil
  
  for i, k in ipairs(self.order) do
    if k == key then
      table.remove(self.order, i)
      break
    end
  end
  
  self.size = self.size - 1
end

function Utils.LRUCache:_moveToFront(key)
  for i, k in ipairs(self.order) do
    if k == key then
      table.remove(self.order, i)
      table.insert(self.order, 1, key)
      break
    end
  end
end

function Utils.LRUCache:_evictOldest()
  if #self.order == 0 then return end
  
  local oldest = self.order[#self.order]
  table.remove(self.order)
  self.cache[oldest] = nil
  self.size = self.size - 1
end

function Utils.LRUCache:cleanup(maxAge)
  local now = computer.uptime()
  local toRemove = {}
  
  for key, value in pairs(self.cache) do
    if type(value) == "table" and value.ts then
      if now - value.ts > maxAge then
        table.insert(toRemove, key)
      end
    end
  end
  
  for _, key in ipairs(toRemove) do
    self:remove(key)
  end
end

function Utils.LRUCache:clear()
  self.cache = {}
  self.order = {}
  self.size = 0
end

function Utils.LRUCache:getSize()
  return self.size
end

return Utils
