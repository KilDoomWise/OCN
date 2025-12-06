local computer = require("computer")

local BGP = {}

BGP.ACTION = {
  ANNOUNCE = "announce",
  WITHDRAW = "withdraw"
}

function BGP.createAnnounce(prefix, mask, origin, nextHop, metric, seq)
  return {
    action = BGP.ACTION.ANNOUNCE,
    prefix = prefix,
    mask = mask,
    origin = origin,
    next_hop = nextHop,
    metric = metric or 1,
    seq = seq or 0,
    ts = computer.uptime()
  }
end

function BGP.createWithdraw(prefix, mask, origin, seq)
  return {
    action = BGP.ACTION.WITHDRAW,
    prefix = prefix,
    mask = mask,
    origin = origin,
    seq = seq or 0,
    ts = computer.uptime()
  }
end

function BGP.parsePrefix(prefixStr)
  local prefix, maskStr = prefixStr:match("^([^/]+)/(%d+)$")
  if not prefix or not maskStr then
    return nil, nil
  end
  return prefix, tonumber(maskStr)
end

function BGP.prefixKey(prefix, mask)
  return prefix .. "/" .. tostring(mask)
end

function BGP.selectBestRoute(routes)
  if not routes or #routes == 0 then
    return nil
  end
  
  local best = routes[1]
  
  for i = 2, #routes do
    local route = routes[i]
    
    if route.metric < best.metric then
      best = route
    elseif route.metric == best.metric then
      if route.seq > best.seq then
        best = route
      elseif route.seq == best.seq then
        if route.origin < best.origin then
          best = route
        end
      end
    end
  end
  
  return best
end

function BGP.updateRoutingTable(routingTable, orsMessage)
  if not orsMessage.prefix or not orsMessage.mask or not orsMessage.origin then
    return false, "Missing required fields"
  end
  
  local key = BGP.prefixKey(orsMessage.prefix, orsMessage.mask)
  
  if orsMessage.action == BGP.ACTION.ANNOUNCE then
    if not routingTable[key] then
      routingTable[key] = {}
    end
    
    local existingIdx = nil
    for i, route in ipairs(routingTable[key]) do
      if route.origin == orsMessage.origin then
        existingIdx = i
        break
      end
    end
    
    if existingIdx then
      if orsMessage.seq >= routingTable[key][existingIdx].seq then
        routingTable[key][existingIdx] = orsMessage
      end
    else
      table.insert(routingTable[key], orsMessage)
    end
    
    return true
  elseif orsMessage.action == BGP.ACTION.WITHDRAW then
    if routingTable[key] then
      for i = #routingTable[key], 1, -1 do
        if routingTable[key][i].origin == orsMessage.origin then
          if orsMessage.seq >= routingTable[key][i].seq then
            table.remove(routingTable[key], i)
          end
        end
      end
      
      if #routingTable[key] == 0 then
        routingTable[key] = nil
      end
    end
    
    return true
  end
  
  return false, "Unknown action"
end

function BGP.lookupRoute(ip, routingTable)
  local bestMatch = nil
  local bestMask = -1
  local bestRoute = nil
  
  for key, routes in pairs(routingTable) do
    local prefix, mask = BGP.parsePrefix(key)
    if prefix and mask then
      if BGP.inSubnet(ip, prefix, mask) then
        if mask > bestMask then
          bestMask = mask
          bestMatch = key
          bestRoute = BGP.selectBestRoute(routes)
        end
      end
    end
  end
  
  return bestRoute
end

function BGP.parseIP(ip)
  local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

function BGP.ipToNumber(ip)
  local a, b, c, d = BGP.parseIP(ip)
  if not a then return nil end
  return a * 16777216 + b * 65536 + c * 256 + d
end

function BGP.inSubnet(ip, subnet, mask)
  local ipNum = BGP.ipToNumber(ip)
  local subnetNum = BGP.ipToNumber(subnet)
  if not ipNum or not subnetNum then return false end
  
  local bits = mask or 24
  local shift = 32 - bits
  
  return math.floor(ipNum / (2 ^ shift)) == math.floor(subnetNum / (2 ^ shift))
end

function BGP.cleanupStaleRoutes(routingTable, maxAge)
  local now = computer.uptime()
  local removed = 0
  
  for key, routes in pairs(routingTable) do
    for i = #routes, 1, -1 do
      if now - routes[i].ts > maxAge then
        table.remove(routes, i)
        removed = removed + 1
      end
    end
    
    if #routes == 0 then
      routingTable[key] = nil
    end
  end
  
  return removed
end

function BGP.getRoutingTableStats(routingTable)
  local prefixes = 0
  local routes = 0
  
  for key, routeList in pairs(routingTable) do
    prefixes = prefixes + 1
    routes = routes + #routeList
  end
  
  return {
    prefixes = prefixes,
    routes = routes
  }
end

return BGP
