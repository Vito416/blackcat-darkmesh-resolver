local function host_lookup_candidates(host)
  local candidates = {}
  if type(host) ~= "string" or host == "" then
    return candidates
  end

  candidates[#candidates + 1] = host
  if host:sub(1, 4) == "www." and #host > 4 then
    local apex = host:sub(5)
    if apex ~= "" then
      candidates[#candidates + 1] = apex
    end
  end

  return candidates
end

local function lookup_host_scoped_entry(map, host)
  if type(map) ~= "table" then
    return nil, nil
  end

  for _, candidate in ipairs(host_lookup_candidates(host)) do
    local entry = map[candidate]
    if entry ~= nil then
      return entry, candidate
    end
  end

  return nil, nil
end
