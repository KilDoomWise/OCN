local filesystem = require("filesystem")
local serialization = require("serialization")
local computer = require("computer")

local Utils = {}

-- ========================================
-- ЛОГИРОВАНИЕ
-- ========================================

function Utils.log(component, msg)
  local timestamp = string.format("[%.2f]", computer.uptime())
  print(timestamp .. " [" .. component .. "] " .. msg)
end

-- ========================================
-- РАБОТА С ТАБЛИЦАМИ
-- ========================================

-- Подсчет элементов в таблице
function Utils.tableSize(tbl)
  if not tbl then return 0 end
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- Глубокое копирование таблицы
function Utils.deepCopy(original)
  if type(original) ~= "table" then
    return original
  end
  
  local copy = {}
  for key, value in pairs(original) do
    if type(value) == "table" then
      copy[key] = Utils.deepCopy(value)
    else
      copy[key] = value
    end
  end
  
  return copy
end

-- Слияние двух таблиц (второя перезаписывает первую)
function Utils.mergeTables(base, override)
  local result = Utils.deepCopy(base) or {}
  
  if override then
    for key, value in pairs(override) do
      result[key] = value
    end
  end
  
  return result
end

-- ========================================
-- РАБОТА С IP АДРЕСАМИ
-- ========================================

function Utils.parseIP(ip)
  if not ip or type(ip) ~= "string" then
    return nil
  end
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  
  -- Валидация диапазонов
  if a < 0 or a > 255 then return nil end
  if b < 0 or b > 255 then return nil end
  if c < 0 or c > 255 then return nil end
  if d < 0 or d > 255 then return nil end
  
  return a, b, c, d
end

function Utils.ipToNumber(ip)
  local a, b, c, d = Utils.parseIP(ip)
  if not a then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

function Utils.numberToIP(num)
  if not num or type(num) ~= "number" then
    return nil
  end
  
  local d = num % 256
  num = math.floor(num / 256)
  local c = num % 256
  num = math.floor(num / 256)
  local b = num % 256
  local a = math.floor(num / 256)
  
  return string.format("%d.%d.%d.%d", a, b, c, d)
end

function Utils.isValidIP(ip)
  return Utils.parseIP(ip) ~= nil
end

function Utils.inSubnet(ip, subnet, mask)
  local ipNum = Utils.ipToNumber(ip)
  local subnetNum = Utils.ipToNumber(subnet)
  
  if not ipNum or not subnetNum then 
    return false 
  end
  
  local bits = mask or 24
  if bits < 0 or bits > 32 then
    return false
  end
  
  local shift = 32 - bits
  
  -- Защита от деления на ноль при mask=32
  if shift == 0 then
    return ipNum == subnetNum
  end
  
  local divisor = 2 ^ shift
  return math.floor(ipNum / divisor) == math.floor(subnetNum / divisor)
end

-- Парсинг CIDR нотации (например "192.168.1.0/24")
function Utils.parseCIDR(cidr)
  if not cidr or type(cidr) ~= "string" then
    return nil, nil
  end
  
  local subnet, maskStr = cidr:match("^([^/]+)/(%d+)$")
  if not subnet or not maskStr then
    return nil, nil
  end
  
  local mask = tonumber(maskStr)
  if not mask or mask < 0 or mask > 32 then
    return nil, nil
  end
  
  if not Utils.isValidIP(subnet) then
    return nil, nil
  end
  
  return subnet, mask
end

-- Longest Prefix Match для маршрутизации
function Utils.longestPrefixMatch(ip, routeTable)
  if not ip or not routeTable then
    return nil
  end
  
  local ipNum = Utils.ipToNumber(ip)
  if not ipNum then 
    return nil 
  end
  
  local bestMatch = nil
  local bestMask = -1
  
  for prefix, route in pairs(routeTable) do
    local subnet, mask = Utils.parseCIDR(prefix)
    if subnet and mask then
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

-- ========================================
-- РАБОТА С ФАЙЛАМИ
-- ========================================

-- Создание директории (рекурсивно)
local function ensureDirectory(path)
  local dir = path:match("^(.+)/[^/]+$")
  if dir and dir ~= "" then
    filesystem.makeDirectory(dir)
  end
end

-- Сохранение таблицы в файл (сериализация)
function Utils.saveTable(path, tbl)
  if not path or not tbl then
    return false
  end
  
  ensureDirectory(path)
  
  local success, file = pcall(io.open, path, "w")
  if not success or not file then 
    return false 
  end
  
  local ok, serialized = pcall(serialization.serialize, tbl)
  if not ok then
    file:close()
    return false
  end
  
  file:write(serialized)
  file:close()
  return true
end

-- Загрузка таблицы из файла (десериализация)
function Utils.loadTable(path)
  if not path or not filesystem.exists(path) then
    return {}
  end
  
  local success, file = pcall(io.open, path, "r")
  if not success or not file then 
    return {} 
  end
  
  local content = file:read("*a")
  file:close()
  
  if not content or content == "" then 
    return {} 
  end
  
  local ok, result = pcall(serialization.unserialize, content)
  if ok and type(result) == "table" then
    return result
  else
    return {}
  end
end

-- Добавление строки в файл
function Utils.appendToFile(path, line)
  if not path or not line then
    return false
  end
  
  ensureDirectory(path)
  
  local success, file = pcall(io.open, path, "a")
  if not success or not file then 
    return false 
  end
  
  file:write(line .. "\n")
  file:close()
  return true
end

-- Чтение файла целиком
function Utils.readFile(path)
  if not path or not filesystem.exists(path) then
    return nil
  end
  
  local success, file = pcall(io.open, path, "r")
  if not success or not file then 
    return nil 
  end
  
  local content = file:read("*a")
  file:close()
  return content
end

-- Запись строки в файл (перезапись)
function Utils.writeFile(path, content)
  if not path then
    return false
  end
  
  ensureDirectory(path)
  
  local success, file = pcall(io.open, path, "w")
  if not success or not file then 
    return false 
  end
  
  file:write(content or "")
  file:close()
  return true
end

-- ========================================
-- РАБОТА С КОНФИГУРАЦИЕЙ (key=value формат)
-- ========================================

function Utils.loadConfig(path)
  if not path or not filesystem.exists(path) then
    return {}
  end
  
  local success, file = pcall(io.open, path, "r")
  if not success or not file then 
    return {} 
  end
  
  local config = {}
  
  local ok = pcall(function()
    for line in file:lines() do
      -- Пропускаем пустые строки и комментарии
      if line and line ~= "" and not line:match("^%s*#") then
        local key, value = line:match("^([^=]+)=(.*)$")
        if key and value then
          -- Убираем пробелы
          key = key:match("^%s*(.-)%s*$")
          value = value:match("^%s*(.-)%s*$")
          config[key] = value
        end
      end
    end
  end)
  
  file:close()
  return config
end

function Utils.saveConfig(path, config)
  if not path or not config then
    return false
  end
  
  ensureDirectory(path)
  
  local success, file = pcall(io.open, path, "w")
  if not success or not file then 
    return false 
  end
  
  -- Сортируем ключи для предсказуемого порядка
  local keys = {}
  for key in pairs(config) do
    table.insert(keys, key)
  end
  table.sort(keys)
  
  for _, key in ipairs(keys) do
    local value = config[key]
    if value ~= nil then
      file:write(string.format("%s=%s\n", tostring(key), tostring(value)))
    end
  end
  
  file:close()
  return true
end

-- ========================================
-- LRU CACHE (Least Recently Used)
-- ========================================

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
    -- Обновляем существующий
    self.cache[key] = value
    self:_moveToFront(key)
  else
    -- Добавляем новый
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
  if not self.cache[key] then 
    return false
  end
  
  self.cache[key] = nil
  
  for i, k in ipairs(self.order) do
    if k == key then
      table.remove(self.order, i)
      break
    end
  end
  
  self.size = self.size - 1
  return true
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
  if #self.order == 0 then 
    return 
  end
  
  local oldest = self.order[#self.order]
  table.remove(self.order)
  self.cache[oldest] = nil
  self.size = self.size - 1
end

-- Очистка записей старше maxAge секунд
-- Записи должны иметь поле .ts с временем создания
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
  
  return #toRemove
end

function Utils.LRUCache:clear()
  self.cache = {}
  self.order = {}
  self.size = 0
end

function Utils.LRUCache:getSize()
  return self.size
end

function Utils.LRUCache:getCapacity()
  return self.capacity
end

-- Получить все ключи
function Utils.LRUCache:keys()
  local result = {}
  for _, key in ipairs(self.order) do
    table.insert(result, key)
  end
  return result
end

-- ========================================
-- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
-- ========================================

-- Безопасное получение подстроки (защита от nil)
function Utils.safeSubstring(str, startPos, endPos)
  if not str or type(str) ~= "string" then
    return ""
  end
  
  endPos = endPos or #str
  if startPos > #str then
    return ""
  end
  
  return string.sub(str, startPos, endPos)
end

-- Разбиение строки по разделителю
function Utils.split(str, delimiter)
  if not str or str == "" then
    return {}
  end
  
  delimiter = delimiter or ","
  local result = {}
  
  for part in str:gmatch("[^" .. delimiter .. "]+") do
    table.insert(result, part)
  end
  
  return result
end

-- Объединение массива в строку
function Utils.join(tbl, delimiter)
  if not tbl or #tbl == 0 then
    return ""
  end
  
  delimiter = delimiter or ","
  return table.concat(tbl, delimiter)
end

-- Проверка пустой таблицы
function Utils.isEmpty(tbl)
  if not tbl then
    return true
  end
  return next(tbl) == nil
end

-- Генерация случайного ID
function Utils.randomID(length)
  length = length or 8
  local chars = "0123456789ABCDEF"
  local result = ""
  
  for i = 1, length do
    local idx = math.random(1, #chars)
    result = result .. chars:sub(idx, idx)
  end
  
  return result
end

-- Форматирование времени uptime
function Utils.formatUptime(seconds)
  if not seconds then
    seconds = computer.uptime()
  end
  
  local hours = math.floor(seconds / 3600)
  local mins = math.floor((seconds % 3600) / 60)
  local secs = math.floor(seconds % 60)
  
  return string.format("%02d:%02d:%02d", hours, mins, secs)
end

-- Безопасный вызов функции (pcall обертка)
function Utils.safeCall(func, ...)
  if type(func) ~= "function" then
    return false, "Not a function"
  end
  
  return pcall(func, ...)
end

return Utils
