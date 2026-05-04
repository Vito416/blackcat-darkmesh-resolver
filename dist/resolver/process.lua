--- The Process library provides an environment for managing and executing processes on the AO network. It includes capabilities for handling messages, spawning processes, and customizing the environment with programmable logic and handlers. Returns the process table.
-- @module process

-- @dependencies
local pretty = require('.pretty')
local base64 = require('.base64')
local json = require('json')
local chance = require('.chance')
local crypto = require('.crypto.init')
local coroutine = require('coroutine')
-- set alias ao for .ao library
if not _G.package.loaded['ao'] then _G.package.loaded['ao'] = require('.ao') end

Colors = {
  red = "\27[31m",
  green = "\27[32m",
  blue = "\27[34m",
  reset = "\27[0m",
  gray = "\27[90m"
}

Bell = "\x07"

Dump = require('.dump')
Utils = require('.utils')
Handlers = require('.handlers')
local stringify = require(".stringify")
local assignment = require('.assignment')
Nonce = Nonce or nil
ao = nil
if _G.package.loaded['.ao'] then
  ao = require('.ao')
elseif _G.package.loaded['ao'] then
  ao = require('ao')
end
-- Implement assignable polyfills on _ao
assignment.init(ao)

--- The process table
-- @table process
-- @field _version The version number of the process

local process = { _version = "2.0.4" }
-- The maximum number of messages to store in the inbox
local maxInboxCount = 10000

-- wrap ao.send and ao.spawn for magic table
local aosend = ao.send
local aospawn = ao.spawn

ao.send = function(msg)
  if msg.Data and type(msg.Data) == 'table' then
    msg['Content-Type'] = 'application/json'
    msg.Data = require('json').encode(msg.Data)
  end
  return aosend(msg)
end
ao.spawn = function(module, msg)
  if msg.Data and type(msg.Data) == 'table' then
    msg['Content-Type'] = 'application/json'
    msg.Data = require('json').encode(msg.Data)
  end
  return aospawn(module, msg)
end

--- Normalizes a message's keys and tags to title case
-- @function normalize
-- @tparam {table} msg The message to normalize
-- @treturn {table} The normalized message
local function normalizeMsg(msg)
  -- Normalize keys to title case
  for key, value in pairs(msg) do
    local normalizedKey = Utils.normalize(key)
    -- Only add to normalizedKeys if the key changed during normalization
    if normalizedKey ~= key then
      msg[key] = nil
      msg[normalizedKey] = value
    end
  end

  -- Normalize tag names to title case
  if msg.Tags and type(msg.Tags) == "table" then
    for i, tag in ipairs(msg.Tags) do
      if tag.name and type(tag.name) == "string" then
        tag.name = Utils.normalize(tag.name)
      end
    end
  end

  -- Bring tags to root message
  ao.normalize(msg)

  return msg
end

--- Remove the last three lines from a string
-- @lfunction removeLastThreeLines
-- @tparam {string} input The string to remove the last three lines from
-- @treturn {string} The string with the last three lines removed
local function removeLastThreeLines(input)
  local lines = {}
  for line in input:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end

  -- Remove the last three lines
  for i = 1, 3 do
    table.remove(lines)
  end

  -- Concatenate the remaining lines
  return table.concat(lines, "\n")
end

--- Insert a message into the inbox and manage overflow
-- @lfunction insertInbox
-- @tparam {table} msg The message to insert into the inbox
local function insertInbox(msg)
  table.insert(Inbox, msg)
  if #Inbox > maxInboxCount then
    local overflow = #Inbox - maxInboxCount
    for i = 1, overflow do
      table.remove(Inbox, 1)
    end
  end
end

--- Find an object in an array by a given key and value
-- @lfunction findObject
-- @tparam {table} array The array to search through
-- @tparam {string} key The key to search for
-- @tparam {any} value The value to search for
local function findObject(array, key, value)
  for i, object in ipairs(array) do
    if object[key] == value then
      return object
    end
  end
  return nil
end

--- Convert a message's tags to a table of key-value pairs
-- @function Tab
-- @tparam {table} msg The message containing tags
-- @treturn {table} A table with tag names as keys and their values
function Tab(msg)
  local inputs = {}
  for _, o in ipairs(msg.Tags) do
    if not inputs[o.name] then
      inputs[o.name] = o.value
    end
  end
  return inputs
end

--- Generate a prompt string for the current process
-- @function Prompt
-- @treturn {string} The custom command prompt string
function Prompt()
  return Colors.green .. Name .. Colors.gray
      .. "@" .. Colors.blue .. "aos-" .. process._version .. Colors.gray
      .. "[Inbox:" .. Colors.red .. tostring(#Inbox) .. Colors.gray
      .. "]" .. Colors.reset .. "> "
end

--- Print a value, formatting tables and converting non-string types
-- @function print
-- @tparam {any} a The value to print
function print(a)
  if type(a) == "table" then
    a = stringify.format(a)
  end
  --[[
In order to print non string types we need to convert to string
  ]]
  if type(a) == "boolean" then
    a = Colors.blue .. tostring(a) .. Colors.reset
  end
  if type(a) == "nil" then
    a = Colors.red .. tostring(a) .. Colors.reset
  end
  if type(a) == "number" then
    a = Colors.green .. tostring(a) .. Colors.reset
  end

  local data = a
  if ao.outbox.Output.data then
    data = ao.outbox.Output.data .. "\n" .. a
  end
  ao.outbox.Output = { data = data, prompt = Prompt(), print = true }

  -- Only supported for newer version of AOS
  if HANDLER_PRINT_LOGS then
    table.insert(HANDLER_PRINT_LOGS, a)
    return nil
  end

  return tostring(a)
end

--- Send a message to a target process
-- @function Send
-- @tparam {table} msg The message to send
function Send(msg)
  if not msg.Target then
    print("WARN: No target specified for message. Data will be stored, but no process will receive it.")
  end
  local result = ao.send(msg)
  return {
    output = "Message added to outbox",
    receive = result.receive,
    onReply = result.onReply
  }
end

--- Spawn a new process
-- @function Spawn
-- @tparam {...any} args The arguments to pass to the spawn function
function Spawn(...)
  local module, spawnMsg

  if select("#", ...) == 1 then
    spawnMsg = select(1, ...)
    module = ao._module
  else
    module = select(1, ...)
    spawnMsg = select(2, ...)
  end

  if not spawnMsg then
    spawnMsg = {}
  end
  local result = ao.spawn(module, spawnMsg)
  return {
    output = "Spawn process request added to outbox",
    after = result.after,
    receive = result.receive
  }
end

--- Calls Handlers.receive with the provided pattern criteria, awaiting a message that matches the criteria.
-- @function Receive
-- @tparam {table} match The pattern criteria for the message
-- @treturn {any} The result of the message handling
function Receive(match)
  return Handlers.receive(match)
end

--- Assigns based on the assignment passed.
-- @function Assign
-- @tparam {table} assignment The assignment to be made
function Assign(assignment)
  if not ao.assign then
    print("Assign is not implemented.")
    return "Assign is not implemented."
  end
  ao.assign(assignment)
  print("Assignment added to outbox.")
  return 'Assignment added to outbox.'
end

Seeded = Seeded or false

--- Converts a string to a seed value
-- @lfunction stringToSeed
-- @tparam {string} s The string to convert to a seed
-- @treturn {number} The seed value
-- this is a temporary approach...
local function stringToSeed(s)
  local seed = 0
  for i = 1, #s do
    local char = string.byte(s, i)
    seed = seed + char
  end
  return seed
end

--- Initializes or updates the state of the process based on the incoming message and environment.
-- @lfunction initializeState
-- @tparam {table} msg The message to initialize the state with
-- @tparam {table} env The environment to initialize the state with
local function initializeState(msg, env)
  if not Seeded then
    local moduleTag = msg.Module
    if not moduleTag and env and env.Process and env.Process.Tags then
      for _, t in ipairs(env.Process.Tags) do
        if t.name == "Module" then
          moduleTag = t.value
          break
        end
      end
    end
    moduleTag = moduleTag or ''
    local ownerTag = msg.Owner or msg.From or ''
    local idTag = msg.Id or (env and env.Process and env.Process.Id) or ''
    chance.seed(tonumber(msg['Block-Height'] .. stringToSeed(ownerTag .. moduleTag .. idTag)))
    math.random = function(...)
      local args = { ... }
      local n = #args
      if n == 0 then
        return chance.random()
      end
      if n == 1 then
        return chance.integer(1, args[1])
      end
      if n == 2 then
        return chance.integer(args[1], args[2])
      end
      return chance.random()
    end
    Seeded = true
  end
  Errors = Errors or {}
  Inbox = Inbox or {}

  -- Owner should only be assiged once
  if env.Process.Id == msg.Id and not Owner then
    local _from = findObject(env.Process.Tags, "name", "From-Process")
    if _from then
      Owner = _from.value
    else
      Owner = msg.From
    end
  end

  if not Name then
    local aosName = findObject(env.Process.Tags, "name", "Name")
    if aosName then
      Name = aosName.value
    else
      Name = 'aos'
    end
  end
end

--- Prints the version of the process
-- @function Version
function Version()
  print("version: " .. process._version)
end

--- Main handler for processing incoming messages. It initializes the state, processes commands, and handles message evaluation and inbox management.
-- @function handle
-- @tparam {table} msg The message to handle
-- @tparam {table} _ The environment to handle the message in
function process.handle(msg, _)
  local env = nil
  if _.Process then
    env = _
  else
    env = _.env
  end

  ao.init(env)
  -- relocate custom tags to root message
  msg = normalizeMsg(msg)
  -- set process id
  ao.id = ao.env.Process.Id
  initializeState(msg, ao.env)
  HANDLER_PRINT_LOGS = {}

  -- set os.time to return msg.Timestamp
  os.time = function() return msg.Timestamp end

  -- tagify msg
  msg.TagArray = msg.Tags
  msg.Tags = Tab(msg)
  -- tagify Process
  ao.env.Process.TagArray = ao.env.Process.Tags
  ao.env.Process.Tags = Tab(ao.env.Process)
  -- magic table - if Content-Type == application/json - decode msg.Data to a Table
  if msg.Tags['Content-Type'] and msg.Tags['Content-Type'] == 'application/json' then
    msg.Data = require('json').decode(msg.Data or "{}")
  end
  -- init Errors
  Errors = Errors or {}
  -- clear Outbox
  ao.clearOutbox()

  -- commented out
  -- -- Only check for Nonce if msg is not read-only and not cron
  -- if not msg['Read-Only'] and not msg['Cron'] then
  --   if not ao.Nonce then
  --     ao.Nonce = tonumber(msg.Nonce)
  --   else
  --     if tonumber(msg.Nonce) ~= (ao.Nonce + 1) then
  --       print(Colors.red .. "WARNING: Nonce did not match, may be due to an error generated by process" .. Colors.reset)
  --       print("")
  --       --return ao.result({Error = "HALT Nonce is out of sync " .. ao.Nonce .. " <> " .. (msg.Nonce or "0") })
  --     end 
  --   end
  -- end

  -- Only trust messages from a signed owner or an Authority
  if msg.From ~= msg.Owner and not ao.isTrusted(msg) then
    -- if msg.From ~= ao.id then
    --   Send({Target = msg.From, Data = "Message is not trusted by this process!"})
    -- end
    print('Message is not trusted! From: ' .. msg.From .. ' - Owner: ' .. msg.Owner)
    return ao.result({})
  end

  if ao.isAssignment(msg) and not ao.isAssignable(msg) then
    if msg.From ~= ao.id then
      Send({ Target = msg.From, Data = "Assignment is not trusted by this process!" })
    end
    print('Assignment is not trusted! From: ' .. msg.From .. ' - Owner: ' .. msg.Owner)
    return ao.result({})
  end

  Handlers.add("_eval",
    function(msg)
      return msg.Action == "Eval" and Owner == msg.From
    end,
    require('.eval')(ao)
  )

  -- Added for aop6 boot loader
  -- See: https://github.com/permaweb/aos/issues/342
  -- Only run bootloader when Process Message is First Message
  if env.Process.Id == msg.Id then
    Handlers.once("_boot",
      function(msg)
        return msg.Tags.Type == "Process" and Owner == msg.From
      end,
      require('.boot')(ao)
    )
  end

  Handlers.append("_default", function() return true end, require('.default')(insertInbox))

-- module: ".registry"
local function _loaded_mod_registry()
  local function _init()
    -- Bundled by hyperengine
    
    -- module: "lustache.scanner"
    local function _loaded_mod_lustache_scanner()
      local string_find, string_match, string_sub =
            string.find, string.match, string.sub
      
      local scanner = {}
      
      -- Returns `true` if the tail is empty (end of string).
      function scanner:eos()
        return self.tail == ""
      end
      
      -- Tries to match the given regular expression at the current position.
      -- Returns the matched text if it can match, `null` otherwise.
      function scanner:scan(pattern)
        local match = string_match(self.tail, pattern)
      
        if match and string_find(self.tail, pattern) == 1 then
          self.tail = string_sub(self.tail, #match + 1)
          self.pos = self.pos + #match
      
          return match
        end
      
      end
      
      -- Skips all text until the given regular expression can be matched. Returns
      -- the skipped string, which is the entire tail of this scanner if no match
      -- can be made.
      function scanner:scan_until(pattern)
      
        local match
        local pos = string_find(self.tail, pattern)
      
        if pos == nil then
          match = self.tail
          self.pos = self.pos + #self.tail
          self.tail = ""
        elseif pos == 1 then
          match = nil
        else
          match = string_sub(self.tail, 1, pos - 1)
          self.tail = string_sub(self.tail, pos)
          self.pos = self.pos + #match
        end
      
        return match
      end
      
      function scanner:new(str)
        local out = {
          str  = str,
          tail = str,
          pos  = 1
        }
        return setmetatable(out, { __index = self } )
      end
      
      return scanner
      
    end
    
    -- module: "lustache.context"
    local function _loaded_mod_lustache_context()
      local function string_split(str, delimiter)
        local returnTable = {}
        for k, v in string.gmatch(str, "([^" .. delimiter .. "]+)") 
        do
            returnTable[#returnTable+1] = k
        end
        return returnTable
      end
      
      local string_find, tostring, type =
            string.find, tostring, type
      
      local context = {}
      context.__index = context
      
      function context:clear_cache()
        self.cache = {}
      end
      
      function context:push(view)
        return self:new(view, self)
      end
      
      function context:lookup(name)
        local value = self.cache[name]
      
        if not value then
          if name == "." then
            value = self.view
          else
            local context = self
      
            while context do
              if string_find(name, ".") > 0 then
                local names = string_split(name, ".")
                local i = 0
      
                value = context.view
      
                if(type(value)) == "number" then
                  value = tostring(value)
                end
      
                while value and i < #names do
                  i = i + 1
                  value = value[names[i]]
                end
              else
                value = context.view[name]
              end
      
              if value then
                break
              end
      
              context = context.parent
            end
          end
      
          self.cache[name] = value
        end
      
        return value
      end
      
      function context:new(view, parent)
        local out = {
          view   = view,
          parent = parent,
          cache  = {},
        }
        return setmetatable(out, context)
      end
      
      return context
      
    end
    
    -- module: "lustache.renderer"
    local function _loaded_mod_lustache_renderer()
      local Scanner  = require "lustache.scanner"
      local Context  = require "lustache.context"
      
      local function string_split(str, delimiter)
        local returnTable = {}
        for k, v in string.gmatch(str, "([^" .. delimiter .. "]+)") 
        do
            returnTable[#returnTable+1] = k
        end
        return returnTable
      end
      
      local error, ipairs, pairs, setmetatable, tostring, type = 
            error, ipairs, pairs, setmetatable, tostring, type 
      local math_floor, math_max, string_find, string_gsub, string_sub, table_concat, table_insert, table_remove =
            math.floor, math.max, string.find, string.gsub, string.sub, table.concat, table.insert, table.remove
      
      local patterns = {
        white = "%s*",
        space = "%s+",
        nonSpace = "%S",
        eq = "%s*=",
        curly = "%s*}",
        tag = "[#\\^/>{&=!]"
      }
      
      local html_escape_characters = {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
        ["'"] = "&#39;",
        ["/"] = "&#x2F;"
      }
      
      local function is_array(array)
        if type(array) ~= "table" then return false end
        local max, n = 0, 0
        for k, _ in pairs(array) do
          if not (type(k) == "number" and k > 0 and math_floor(k) == k) then
            return false 
          end
          max = math_max(max, k)
          n = n + 1
        end
        return n == max
      end
      
      -- Low-level function that compiles the given `tokens` into a
      -- function that accepts two arguments: a Context and a
      -- Renderer.
      
      local function compile_tokens(tokens, originalTemplate)
        local subs = {}
      
        local function subrender(i, tokens)
          if not subs[i] then
            local fn = compile_tokens(tokens, originalTemplate)
            subs[i] = function(ctx, rnd) return fn(ctx, rnd) end
          end
          return subs[i]
        end
      
        local function render(ctx, rnd)
          local buf = {}
          local token, section
          for i, token in ipairs(tokens) do
            local t = token.type
            buf[#buf+1] = 
              t == "#" and rnd:_section(
                token, ctx, subrender(i, token.tokens), originalTemplate
              ) or
              t == "^" and rnd:_inverted(
                token.value, ctx, subrender(i, token.tokens)
              ) or
              t == ">" and rnd:_partial(token.value, ctx, originalTemplate) or
              (t == "{" or t == "&") and rnd:_name(token.value, ctx, false) or
              t == "name" and rnd:_name(token.value, ctx, true) or
              t == "text" and token.value or ""
          end
          return table_concat(buf)
        end
        return render
      end
      
      local function escape_tags(tags)
      
        return {
          string_gsub(tags[1], "%%", "%%%%").."%s*",
          "%s*"..string_gsub(tags[2], "%%", "%%%%"),
        }
      end
      
      local function nest_tokens(tokens)
        local tree = {}
        local collector = tree 
        local sections = {}
        local token, section
      
        for i,token in ipairs(tokens) do
          if token.type == "#" or token.type == "^" then
            token.tokens = {}
            sections[#sections+1] = token
            collector[#collector+1] = token
            collector = token.tokens
          elseif token.type == "/" then
            if #sections == 0 then
              error("Unopened section: "..token.value)
            end
      
            -- Make sure there are no open sections when we're done
            section = table_remove(sections, #sections)
      
            if not section.value == token.value then
              error("Unclosed section: "..section.value)
            end
      
            section.closingTagIndex = token.startIndex
      
            if #sections > 0 then
              collector = sections[#sections].tokens
            else
              collector = tree
            end
          else
            collector[#collector+1] = token
          end
        end
      
        section = table_remove(sections, #sections)
      
        if section then
          error("Unclosed section: "..section.value)
        end
      
        return tree
      end
      
      -- Combines the values of consecutive text tokens in the given `tokens` array
      -- to a single token.
      local function squash_tokens(tokens)
        local out, txt = {}, {}
        local txtStartIndex, txtEndIndex
        for _, v in ipairs(tokens) do
          if v.type == "text" then
            if #txt == 0 then
              txtStartIndex = v.startIndex
            end
            txt[#txt+1] = v.value
            txtEndIndex = v.endIndex
          else
            if #txt > 0 then
              out[#out+1] = { type = "text", value = table_concat(txt), startIndex = txtStartIndex, endIndex = txtEndIndex }
              txt = {}
            end
            out[#out+1] = v
          end
        end
        if #txt > 0 then
          out[#out+1] = { type = "text", value = table_concat(txt), startIndex = txtStartIndex, endIndex = txtEndIndex  }
        end
        return out
      end
      
      local function make_context(view)
        if not view then return view end
        return getmetatable(view) == Context and view or Context:new(view)
      end
      
      local renderer = { }
      
      function renderer:clear_cache()
        self.cache = {}
        self.partial_cache = {}
      end
      
      function renderer:compile(tokens, tags, originalTemplate)
        tags = tags or self.tags
        if type(tokens) == "string" then
          tokens = self:parse(tokens, tags)
        end
      
        local fn = compile_tokens(tokens, originalTemplate)
      
        return function(view)
          return fn(make_context(view), self)
        end
      end
      
      function renderer:render(template, view, partials)
        if type(self) == "string" then
          error("Call mustache:render, not mustache.render!")
        end
      
        if partials then
          -- remember partial table
          -- used for runtime lookup & compile later on
          self.partials = partials
        end
      
        if not template then
          return ""
        end
      
        local fn = self.cache[template]
      
        if not fn then
          fn = self:compile(template, self.tags, template)
          self.cache[template] = fn
        end
      
        return fn(view)
      end
      
      function renderer:_section(token, context, callback, originalTemplate)
        local value = context:lookup(token.value)
      
        if type(value) == "table" then
          if is_array(value) then
            local buffer = ""
      
            for i,v in ipairs(value) do
              buffer = buffer .. callback(context:push(v), self)
            end
      
            return buffer
          end
      
          return callback(context:push(value), self)
        elseif type(value) == "function" then
          local section_text = string_sub(originalTemplate, token.endIndex+1, token.closingTagIndex - 1)
      
          local scoped_render = function(template)
            return self:render(template, context)
          end
      
          return value(section_text, scoped_render) or ""
        else
          if value then
            return callback(context, self)
          end
        end
      
        return ""
      end
      
      function renderer:_inverted(name, context, callback)
        local value = context:lookup(name)
      
        -- From the spec: inverted sections may render text once based on the
        -- inverse value of the key. That is, they will be rendered if the key
        -- doesn't exist, is false, or is an empty list.
      
        if value == nil or value == false or (type(value) == "table" and is_array(value) and #value == 0) then
          return callback(context, self)
        end
      
        return ""
      end
      
      function renderer:_partial(name, context, originalTemplate)
        local fn = self.partial_cache[name]
      
        -- check if partial cache exists
        if (not fn and self.partials) then
      
          local partial = self.partials[name]
          if (not partial) then
            return ""
          end
          
          -- compile partial and store result in cache
          fn = self:compile(partial, nil, originalTemplate)
          self.partial_cache[name] = fn
        end
        return fn and fn(context, self) or ""
      end
      
      function renderer:_name(name, context, escape)
        local value = context:lookup(name)
      
        if type(value) == "function" then
          value = value(context.view)
        end
      
        local str = value == nil and "" or value
        str = tostring(str)
      
        if escape then
          return string_gsub(str, '[&<>"\'/]', function(s) return html_escape_characters[s] end)
        end
      
        return str
      end
      
      -- Breaks up the given `template` string into a tree of token objects. If
      -- `tags` is given here it must be an array with two string values: the
      -- opening and closing tags used in the template (e.g. ["<%", "%>"]). Of
      -- course, the default is to use mustaches (i.e. Mustache.tags).
      function renderer:parse(template, tags)
        tags = tags or self.tags
        local tag_patterns = escape_tags(tags)
        local scanner = Scanner:new(template)
        local tokens = {} -- token buffer
        local spaces = {} -- indices of whitespace tokens on the current line
        local has_tag = false -- is there a {{tag} on the current line?
        local non_space = false -- is there a non-space char on the current line?
      
        -- Strips all whitespace tokens array for the current line if there was
        -- a {{#tag}} on it and otherwise only space
        local function strip_space()
          if has_tag and not non_space then
            while #spaces > 0 do
              table_remove(tokens, table_remove(spaces))
            end
          else
            spaces = {}
          end
          has_tag = false
          non_space = false
        end
      
        local type, value, chr
      
        while not scanner:eos() do
          local start = scanner.pos
      
          value = scanner:scan_until(tag_patterns[1])
      
          if value then
            for i = 1, #value do
              chr = string_sub(value,i,i)
      
              if string_find(chr, "%s+") then
                spaces[#spaces+1] = #tokens + 1
              else
                non_space = true
              end
      
              tokens[#tokens+1] = { type = "text", value = chr, startIndex = start, endIndex = start }
              start = start + 1
              if chr == "\n" then
                strip_space()
              end
            end
          end
      
          if not scanner:scan(tag_patterns[1]) then
            break
          end
      
          has_tag = true
          type = scanner:scan(patterns.tag) or "name"
      
          scanner:scan(patterns.white)
      
          if type == "=" then
            value = scanner:scan_until(patterns.eq)
            scanner:scan(patterns.eq)
            scanner:scan_until(tag_patterns[2])
          elseif type == "{" then
            local close_pattern = "%s*}"..tags[2]
            value = scanner:scan_until(close_pattern)
            scanner:scan(patterns.curly)
            scanner:scan_until(tag_patterns[2])
          else
            value = scanner:scan_until(tag_patterns[2])
          end
      
          if not scanner:scan(tag_patterns[2]) then
            error("Unclosed tag at " .. scanner.pos)
          end
      
          tokens[#tokens+1] = { type = type, value = value, startIndex = start, endIndex = scanner.pos - 1 }
          if type == "name" or type == "{" or type == "&" then
            non_space = true --> what does this do?
          end
      
          if type == "=" then
            tags = string_split(value, patterns.space)
            tag_patterns = escape_tags(tags)
          end
        end
      
        return nest_tokens(squash_tokens(tokens))
      end
      
      function renderer:new()
        local out = { 
          cache         = {},
          partial_cache = {},
          tags          = {"{{", "}}"}
        }
        return setmetatable(out, { __index = self })
      end
      
      return renderer
      
    end
    
    -- module: "lustache"
    local function _loaded_mod_lustache()
      -- lustache: Lua mustache template parsing.
      -- Copyright 2013 Olivine Labs, LLC <projects@olivinelabs.com>
      -- MIT Licensed.
      
      local string_gmatch = string.gmatch
      
      function string.split(str, sep)
        local out = {}
        for m in string_gmatch(str, "[^"..sep.."]+") do out[#out+1] = m end
        return out
      end
      
      local lustache = {
        name     = "lustache",
        version  = "1.3.1-0",
        renderer = require("lustache.renderer"):new(),
      }
      
      return setmetatable(lustache, {
        __index = function(self, idx)
          if self.renderer[idx] then return self.renderer[idx] end
        end,
        __newindex = function(self, idx, val)
          if idx == "partials" then self.renderer.partials = val end
          if idx == "tags" then self.renderer.tags = val end
        end
      })
      
    end
    
    -- module: "hyperengine"
    local function _loaded_mod_hyperengine()
      --- Hyperengine: A template management runtime for AO processes.
      --- Provides CRUD operations for Mustache templates, rendering with partials,
      --- automatic dependency-aware re-rendering, role-based access control,
      --- and persistent state sync to HyperBEAM's `patch@1.0` device.
      ---@module 'hyperengine'
      
      ---@alias TemplateMap table<string, string> Template key to content mapping
      ---@alias ACL table<string, table<string, boolean>> Address to role-set mapping (address → { role → true })
      ---@alias PatchMap table<string, string> Patch path to rendered HTML mapping
      ---@alias PublishedRegistry table<string, HyperenginePublishedEntry> Patch path to published entry mapping
      ---@alias DataProvider table|fun():table Static data table or dynamic data function callback
      
      --- Internal registration entry stored in `hyperengine_published`.
      ---@class HyperenginePublishedEntry
      ---@field key string Template key that was published
      ---@field data? table Static data table (nil when using a data function)
      ---@field dataFn? fun():table Dynamic data function called on each re-render
      ---@field partials? TemplateMap Additional partials passed at publish time
      ---@field statePath? string Dot-notation path to a Lua global used as dynamic data source
      
      --- Published template info returned by `get_state()`.
      ---@class HyperenginePublishedInfo
      ---@field path string The patch path this template is published to
      ---@field template_name string The template key used for rendering
      ---@field partials? TemplateMap Additional partials passed at publish time
      ---@field statePath? string Dot-notation path to a Lua global used as data source
      ---@field re_render_on_state_change boolean Whether this entry auto-rerenders on template changes
      
      --- State snapshot returned by `get_state()`.
      ---@class HyperengineState
      ---@field templates string[] Array of all template keys
      ---@field published HyperenginePublishedInfo[] Array of published template info entries
      ---@field acl ACL The current access control list
      
      ---@class hyperengine
      local _ok_templates, _bundled = pcall(require, "templates")
      if not _ok_templates then _bundled = {} end
      local _patch_key = "ui"
      local _state_key = "hyperengine_state"
      
      ---@type TemplateMap Persistent template storage; survives AO process reloads via lowercase globals.
      if not hyperengine_templates then
        hyperengine_templates = {}
      end
      for k, v in pairs(_bundled) do
        if hyperengine_templates[k] == nil then
          hyperengine_templates[k] = v
        end
      end
      
      ---@type ACL Role-based access control list; `{ [address] = { [role] = true } }`.
      if not hyperengine_acl then
        hyperengine_acl = { [ao.env.Process.Owner] = { owner = true } }
      end
      
      ---@type PatchMap Accumulated HTML patches keyed by patch path, sent to `patch@1.0`.
      if not hyperengine_patches then
        hyperengine_patches = {}
      end
      
      ---@type PublishedRegistry Registry of published templates for auto-rerender tracking.
      if not hyperengine_published then
        hyperengine_published = {}
      end
      
      local lustache = require("lustache")
      
      --- Resolve a dot-notation path against the Lua global table `_G`.
      --- For example, `"state.config.title"` traverses `_G.state.config.title`.
      ---@private
      ---@param path string Dot-notation path (e.g. `"state.config.title"`)
      ---@return any|nil value The resolved value, or `nil` if any segment is missing
      local function _resolve_path(path)
        local current = _G
        for segment in path:gmatch("[^%.]+") do
          if type(current) ~= "table" then return nil end
          current = current[segment]
        end
        return current
      end
      
      --- Extract all Mustache partial references (`{{>name}}`) from a template string.
      ---@private
      ---@param content string|any Template content to scan (non-strings return empty table)
      ---@return table<string, boolean> refs Set of partial names found (name → `true`)
      local function _find_partial_refs(content)
        local refs = {}
        if type(content) ~= "string" then
          return refs
        end
        for name in content:gmatch("{{>%s*([%w_%.%-/]+)%s*}}") do
          refs[name] = true
        end
        return refs
      end
      
      --- Set a value in a nested table by splitting `path` on `/`.
      --- For example, `_deep_set(t, "a/b/c", v)` produces `t.a.b.c = v`,
      --- creating intermediate tables as needed.
      ---@private
      ---@param tbl table Root table to write into
      ---@param path string Slash-delimited path (e.g. `"admin/index.html"`)
      ---@param value any Value to store at the leaf
      local function _deep_set(tbl, path, value)
        local segments = {}
        for seg in path:gmatch("[^/]+") do
          segments[#segments + 1] = seg
        end
        if #segments == 0 then return end
        local current = tbl
        for i = 1, #segments - 1 do
          if type(current[segments[i]]) ~= "table" then
            current[segments[i]] = {}
          end
          current = current[segments[i]]
        end
        current[segments[#segments]] = value
      end
      
      --- Remove a leaf value from a nested table by splitting `path` on `/`.
      ---@private
      ---@param tbl table Root table to remove from
      ---@param path string Slash-delimited path
      local function _deep_remove(tbl, path)
        local segments = {}
        for seg in path:gmatch("[^/]+") do
          segments[#segments + 1] = seg
        end
        if #segments == 0 then return end
        local current = tbl
        for i = 1, #segments - 1 do
          if type(current[segments[i]]) ~= "table" then return end
          current = current[segments[i]]
        end
        current[segments[#segments]] = nil
      end
      
      local function _deep_copy(orig, copies)
        copies = copies or {}
        local orig_type = type(orig)
        local copy
        if orig_type == 'table' then
          if copies[orig] then
            copy = copies[orig]
          else
            copy = {}
            copies[orig] = copy
            for orig_key, orig_value in next, orig, nil do
              copy[_deep_copy(orig_key, copies)] = _deep_copy(orig_value, copies)
            end
            setmetatable(copy, _deep_copy(getmetatable(orig), copies))
          end
        else -- number, string, boolean, etc
          copy = orig
        end
        return copy
      end
      
      --- Recursively check whether `template_key` depends on `changed_key` via partial references.
      --- Performs a depth-first traversal through the partial dependency graph with cycle detection.
      ---@private
      ---@param template_key string The template to check for dependency
      ---@param changed_key string The template key that was modified
      ---@param seen? table<string, boolean> Visited set for cycle detection (created internally)
      ---@return boolean depends `true` if `template_key` depends on `changed_key` (directly or transitively)
      local function _depends_on(template_key, changed_key, seen)
        if not seen then seen = {} end
        if seen[template_key] then return false end
        seen[template_key] = true
        local content = hyperengine_templates[template_key]
        if not content then return false end
        local refs = _find_partial_refs(content)
        if refs[changed_key] then return true end
        for ref_key in pairs(refs) do
          if _depends_on(ref_key, changed_key, seen) then
            return true
          end
        end
        return false
      end
      
      --- Re-render all published templates that depend on `changed_key`.
      --- Iterates over `hyperengine_published`, checks direct key match and transitive
      --- partial dependencies, re-renders affected templates, and sends a batched
      --- `patch@1.0` message if any output changed.
      ---@private
      ---@param changed_key string The template key that was modified
      local function _auto_rerender(changed_key)
        local any_changed = false
        for patchPath, published in pairs(hyperengine_published) do
          if published.template_key == changed_key or _depends_on(published.template_key, changed_key) then
            local data = published.data
            if type(published.dataFn) == "function" then
              local ok, result = pcall(published.dataFn)
              if ok then data = result end
            end
            local ok, html = pcall(lustache.render, lustache, hyperengine_templates[published.template_key] or "", data or {}, hyperengine_templates)
            if ok then
              _deep_set(hyperengine_patches, patchPath, html)
              any_changed = true
            end
          end
        end
        if any_changed then
          Send({ device = "patch@1.0", [_patch_key] = hyperengine_patches })
        end
      end
      
      local hyperengine = {}
      
      --- Return a snapshot of the current hyperengine state.
      --- Includes template keys, published template info, and the ACL.
      ---@return HyperengineState state Current state snapshot
      function hyperengine.get_state()
        local state = {
          templates = {},
          published = {},
          acl = hyperengine_acl,
          ui_root = _patch_key
        }
        for template_key, _ in pairs(hyperengine_templates) do
          table.insert(state.templates, template_key)
        end
        for patchPath, published in pairs(hyperengine_published) do
          table.insert(state.published, {
            path = patchPath,
            template_name = published.template_key,
            partials = published.partials,
            statePath = published.statePath,
            re_render_on_state_change = type(published.dataFn) == "function" or type(published.data) == "table"
          })
        end
      
        return state
      end
      
      --- Sync current templates, ACL, and published state to `patch@1.0`.
      --- Triggers an auto-rerender of the admin interface and sends all
      --- accumulated patches, state, templates, and published registry in a single message.
      function hyperengine.sync()
        local hyperengine_state = hyperengine.get_state()
        -- _auto_rerender('admin/index.html')
      
        for _, published in pairs(hyperengine_published) do
          hyperengine.republishTemplate(published.template_key)
        end
      
        Send({
          device = "patch@1.0",
          [_patch_key] = hyperengine_patches,
          [_state_key] = hyperengine_state,
          hyperengine_templates = hyperengine_templates,
          hyperengine_published = hyperengine_published
        })
      end
      
      -- function hyperengine.sync_rerender()
      --   Send({
      --     device = "patch@1.0",
      --     [_patch_key] = hyperengine_patches
      --   })
      -- end
      
      --- Retrieve template content by key.
      ---@param key string Template key (e.g. `"index.html"`)
      ---@return string|nil content Template content, or `nil` if not found
      function hyperengine.get(key)
        return hyperengine_templates[key]
      end
      
      --- Create or update a template.
      --- Stores the content, syncs state to `patch@1.0`, and triggers auto-rerender
      --- of all published templates that depend on this key.
      ---@param key string Template key (e.g. `"index.html"`)
      ---@param content string Template content (Mustache syntax)
      function hyperengine.set(key, content)
        hyperengine_templates[key] = content
        hyperengine.sync()
        -- _auto_rerender(key)
      end
      
      --- Delete a template and clean up any published entries that reference it.
      --- Removes the template from storage, unpublishes all entries using this key,
      --- syncs state, and triggers auto-rerender for any remaining dependents.
      ---@param key string Template key to remove
      function hyperengine.remove(key)
        hyperengine_templates[key] = nil
        for patchPath, published in pairs(hyperengine_published) do
          if published.template_key == key then
            hyperengine_published[patchPath] = nil
            _deep_remove(hyperengine_patches, patchPath)
          end
        end
        hyperengine.sync()
        -- _auto_rerender(key)
      end
      
      --- Return an array of all stored template keys.
      ---@return string[] keys List of template keys
      function hyperengine.list()
        local keys = {}
        for k in pairs(hyperengine_templates) do
          keys[#keys + 1] = k
        end
        return keys
      end
      
      --- Render a stored template by key with optional data and partials.
      --- All stored templates are automatically available as partials. Explicit
      --- partials override stored templates with the same key.
      ---@param template_key string Template key to render
      ---@param data? table Data context for Mustache rendering
      ---@param partials? TemplateMap Additional partials to merge (override stored templates)
      ---@return string html Rendered HTML output
      ---@error Throws if the template key is not found
      function hyperengine.renderTemplate(template_key, data, partials)
        local tmpl = hyperengine_templates[template_key]
        assert(type(tmpl) == "string", "template not found: " .. tostring(template_key))
        lustache.renderer:clear_cache()
        return lustache:render(tmpl, data, partials)
      end
      
      --- Render a raw Mustache template string with optional data and partials.
      --- All stored templates are automatically available as partials. Explicit
      --- partials override stored templates with the same key.
      ---@param template string Mustache template string to render
      ---@param data? table Data context for Mustache rendering
      ---@param partials? TemplateMap Additional partials to merge (override stored templates)
      ---@return string html Rendered HTML output
      ---@error Throws if `template` is not a string
      function hyperengine.render(template, data, partials)
        assert(type(template) == "string", "expected string template, got " .. type(template))
        lustache.renderer:clear_cache()
        return lustache:render(template, data, partials)
      end
      
      --- Check whether an address has permission to perform an action.
      --- Permission is granted if any of the following are true:
      --- 1. The address is the process `Owner` (always authorized)
      --- 2. The address has the `"admin"` role (authorized for everything)
      --- 3. The address has a role matching the exact `action` name
      ---@param address string The wallet address to check
      ---@param action string The action name (e.g. `"Hyperengine-Set"`, `"admin"`)
      ---@return boolean authorized `true` if the address is permitted
      function hyperengine.has_permission(address, action)
        if address == Owner then
          return true
        end
        local roles = hyperengine_acl[address]
        if not roles then
          return false
        end
        if roles["admin"] then
          return true
        end
        return roles[action] == true
      end
      
      --- Grant a role to an address.
      --- Creates the ACL entry for the address if it doesn't exist.
      ---@param address string The wallet address to grant the role to
      ---@param role string The role to grant (e.g. `"admin"`, `"Hyperengine-Set"`)
      function hyperengine.grant(address, role)
        if not hyperengine_acl[address] then
          hyperengine_acl[address] = {}
        end
        hyperengine_acl[address][role] = true
        hyperengine.sync()
      end
      
      --- Revoke a role from an address.
      --- No-op if the address has no ACL entry.
      ---@param address string The wallet address to revoke the role from
      ---@param role string The role to revoke
      function hyperengine.revoke(address, role)
        if not hyperengine_acl[address] then
          return
        end
        hyperengine_acl[address][role] = nil
        hyperengine.sync()
      end
      
      --- Get roles for a specific address, or the entire ACL if no address is given.
      ---@param address? string Wallet address to query (omit for full ACL)
      ---@return table<string, boolean>|ACL roles Role set for the address, or the full ACL table
      function hyperengine.get_roles(address)
        if address then
          return hyperengine_acl[address] or {}
        end
        return hyperengine_acl
      end
      
      --- List all currently published templates.
      ---@return table<string, { key: string, statePath: string? }> published Map of patch path to published template info
      function hyperengine.listPublished()
        local result = {}
        for patchPath, published in pairs(hyperengine_published) do
          result[patchPath] = {
            template_key = published.template_key,
            statePath = published.statePath
          }
        end
        return result
      end
      
      --- Render a template and register it for automatic re-rendering.
      --- When any template this one depends on changes (directly or via partials),
      --- it will be automatically re-rendered and re-published.
      ---
      --- The `data` parameter can be:
      --- - A **table**: stored as static data, re-used on each auto-rerender.
      --- - A **function**: called on each render to produce fresh data (useful for live dashboards).
      ---
      ---@param template_key string Template key to render
      ---@param ui_path string Path to publish rendered output to via `patch@1.0`
      ---@param data? DataProvider Data table or function returning data for rendering
      ---@param partials? TemplateMap Additional partials for rendering
      ---@param statePath? string Dot-notation path to a Lua global used as dynamic data source
      ---@return string html The rendered HTML output
      function hyperengine.publishTemplate(template_key, ui_path, data, partials, statePath)
        local dataFn = nil
        local renderData = data
        if type(data) == "function" then
          dataFn = data
          renderData = data()
        end
        local partialsCopy = _deep_copy(partials)
        local html = hyperengine.renderTemplate(template_key, renderData or {}, partialsCopy)
        hyperengine_published[ui_path] = {
          template_key = template_key,
          data = (type(data) ~= "function") and data or nil,
          dataFn = dataFn,
          partials = partialsCopy,
          statePath = statePath
        }
        _deep_set(hyperengine_patches, ui_path, html)
      
        return html
      end
      
      function hyperengine.republishTemplate(template_key)
        for patchPath, published in pairs(hyperengine_published) do
          if published.template_key == template_key then
            hyperengine.publishTemplate(published.template_key, patchPath, published.dataFn or published.data, published.partials, published.statePath)
          end
        end
      end
      
      --- Stop publishing a template at the given patch path.
      --- Removes the registration and clears the patch, then sends updated patches.
      ---@param patchPath string The patch path to unpublish
      function hyperengine.unpublishTemplate(patchPath)
        hyperengine_published[patchPath] = nil
        _deep_remove(hyperengine_patches, patchPath)
        Send({ device = "patch@1.0", [_patch_key] = hyperengine_patches })
      end
      
      --- Accumulate HTML patches without sending them.
      --- Merges the provided patches into `hyperengine_patches`. Call `publish()` to send.
      ---@param patches PatchMap Patch path to HTML content mapping
      function hyperengine.patch(patches)
        for k, v in pairs(patches) do
          _deep_set(hyperengine_patches, k, v)
        end
      end
      
      --- Publish all accumulated patches to `patch@1.0`.
      --- Optionally merges additional patches before sending.
      ---@param patches? PatchMap Additional patches to merge before publishing
      function hyperengine.publish(patches)
        if patches then
          for k, v in pairs(patches) do
            _deep_set(hyperengine_patches, k, v)
          end
        end
        Send({ device = "patch@1.0", [_patch_key] = hyperengine_patches })
      end
      
      --- Register all AO message handlers for remote template management.
      --- Adds 12 handlers to the AO `Handlers` table:
      ---
      --- **Public (no auth required):**
      --- - `Hyperengine-Get` — Retrieve template content (Tag: `Key`)
      --- - `Hyperengine-List` — List all template keys
      --- - `Hyperengine-RenderTemplate` — Render stored template (Tag: `Key`, Body: JSON `{data, partials}`)
      --- - `Hyperengine-Render` — Render raw template string (Body: JSON `{template, data, partials}`)
      --- - `Hyperengine-Get-Roles` — Query ACL roles (Tag: `Address` optional)
      --- - `Hyperengine-List-Published` — List all published templates
      ---
      --- **Owner/Admin/Per-action role required:**
      --- - `Hyperengine-Set` — Create/update template (Tag: `Key`, Body: content)
      --- - `Hyperengine-Remove` — Delete template (Tag: `Key`)
      --- - `Hyperengine-Publish-Template` — Publish rendered template (Tags: `Template-Name`, `Publish-Path`, `State-Path?`)
      --- - `Hyperengine-Unpublish-Template` — Stop publishing (Tag: `Path`)
      ---
      --- **Owner/Admin only:**
      --- - `Hyperengine-Grant-Role` — Grant role (Tags: `Address`, `Role`)
      --- - `Hyperengine-Revoke-Role` — Revoke role (Tags: `Address`, `Role`)
      function hyperengine.handlers()
        Handlers.add("Hyperengine-Get",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Get"),
          function(msg)
            local template_key = msg.Tags['Template-Key']
            local tmpl = hyperengine.get(template_key)
            Send({ Target = msg.From, Action = 'Hyperengine-Get-Response', Data = tmpl or "" })
          end
        )
      
        Handlers.add("Hyperengine-List",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-List"),
          function(msg)
            local keys = hyperengine.list()
            Send({ Target = msg.From, Action = 'Hyperengine-List-Response', Data = table.concat(keys, "\n") })
          end
        )
      
        Handlers.add("Hyperengine-RenderTemplate",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-RenderTemplate"),
          function(msg)
            local template_key = msg.Tags['Template-Key']
            local ok, parsed = pcall(json.decode, msg.Data or "{}")
            if not ok then
              Send({ Target = msg.From, Action = 'Hyperengine-RenderTemplate-Response', Data = "", Error = "invalid JSON: " .. tostring(parsed) })
              return
            end
            local ok2, result = pcall(hyperengine.renderTemplate, template_key, parsed.data or {}, parsed.partials)
            if ok2 then
              Send({ Target = msg.From, Action = 'Hyperengine-RenderTemplate-Response', Data = result })
            else
              Send({ Target = msg.From, Action = 'Hyperengine-RenderTemplate-Response', Data = "", Error = result })
            end
          end
        )
      
        Handlers.add("Hyperengine-Render",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Render"),
          function(msg)
            local ok, parsed = pcall(json.decode, msg.Data or "{}")
            if not ok then
              Send({ Target = msg.From, Action = 'Hyperengine-Render-Response', Data = "", Error = "invalid JSON: " .. tostring(parsed) })
              return
            end
            local tmpl = parsed.template or ""
            local ok2, result = pcall(hyperengine.render, tmpl, parsed.data or {}, parsed.partials)
            if ok2 then
              Send({ Target = msg.From, Action = 'Hyperengine-Render-Response', Data = result })
            else
              Send({ Target = msg.From, Action = 'Hyperengine-Render-Response', Data = "", Error = result })
            end
          end
        )
      
        Handlers.add("Hyperengine-Set",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Set"),
          function(msg)
            assert(hyperengine.has_permission(msg.From, "Hyperengine-Set"), "not authorized to set templates")
            local template_key = msg.Tags['Template-Key']
            assert(type(template_key) == "string" and template_key ~= "", "Template-Key tag is required and must be a non-empty string")
            hyperengine.set(template_key, msg.Data)
            Send({ Target = msg.From, Action = 'Hyperengine-Set-Response', Data = 'OK' })
          end
        )
      
        Handlers.add("Hyperengine-Remove",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Remove"),
          function(msg)
            assert(hyperengine.has_permission(msg.From, "Hyperengine-Remove"), "not authorized to remove templates")
            local template_key = msg.Tags['Template-Key']
            hyperengine.remove(template_key)
            Send({ Target = msg.From, Action = 'Hyperengine-Remove-Response', Data = 'OK' })
          end
        )
      
        Handlers.add("Hyperengine-Grant-Role",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Grant-Role"),
          function(msg)
            assert(hyperengine.has_permission(msg.From, "admin"), "not authorized to manage roles")
            local address = msg.Tags.Address or msg.Tags.address
            local role = msg.Tags.Role or msg.Tags.role
            assert(address, "Address tag is required")
            assert(role, "Role tag is required")
            if msg.From ~= Owner then
              assert(role ~= "admin", "only the owner can grant admin role")
            end
            hyperengine.grant(address, role)
            Send({ Target = msg.From, Action = 'Hyperengine-Grant-Role-Response', Data = 'OK' })
          end
        )
      
        Handlers.add("Hyperengine-Revoke-Role",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Revoke-Role"),
          function(msg)
            assert(hyperengine.has_permission(msg.From, "admin"), "not authorized to manage roles")
            local address = msg.Tags.Address or msg.Tags.address
            local role = msg.Tags.Role or msg.Tags.role
            assert(address, "Address tag is required")
            assert(role, "Role tag is required")
            if msg.From ~= Owner then
              assert(role ~= "admin", "only the owner can revoke admin role")
            end
            hyperengine.revoke(address, role)
            Send({ Target = msg.From, Action = 'Hyperengine-Revoke-Role-Response', Data = 'OK' })
          end
        )
      
        Handlers.add("Hyperengine-Get-Roles",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Get-Roles"),
          function(msg)
            local address = msg.Tags.Address or msg.Tags.address
            local roles = hyperengine.get_roles(address)
            if address then
              local keys = {}
              for k in pairs(roles) do
                keys[#keys + 1] = k
              end
              Send({ Target = msg.From, Action = 'Hyperengine-Get-Roles-Response', Data = table.concat(keys, "\n") })
            else
              local lines = {}
              for addr, r in pairs(roles) do
                local keys = {}
                for k in pairs(r) do
                  keys[#keys + 1] = k
                end
                lines[#lines + 1] = addr .. ":" .. table.concat(keys, ",")
              end
              Send({ Target = msg.From, Action = 'Hyperengine-Get-Roles-Response', Data = table.concat(lines, "\n") })
            end
          end
        )
      
        Handlers.add("Hyperengine-Publish-Template",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Publish-Template"),
          function(msg)
            assert(hyperengine.has_permission(msg.From, "Hyperengine-Publish-Template"), "not authorized to publish templates")
            local template_key = msg.Tags['Template-Key']
            local publish_path = msg.Tags['Publish-Path']
            assert(template_key, "Template-Key tag is required, got: " .. tostring(template_key))
            assert(publish_path, "Publish-Path tag is required, got: " .. tostring(publish_path))
            local statePath = msg.Tags["State-Path"] or msg.Tags["state-path"]
            local data = {}
            if statePath then
              local resolved = _resolve_path(statePath)
              if type(resolved) == "table" then
                data = function() return _resolve_path(statePath) end
              elseif type(resolved) == "function" then
                data = resolved
              end
            elseif msg.Data and msg.Data ~= "" then
              local ok, parsed = pcall(json.decode, msg.Data)
              if ok and type(parsed) == "table" then
                data = parsed
              end
            end
            local ok, result = pcall(hyperengine.publishTemplate, template_key, publish_path, data, nil, statePath)
            if ok then
              hyperengine.sync()
              Send({ Target = msg.From, Action = 'Hyperengine-Publish-Template-Response', Data = 'OK' })
            else
              Send({ Target = msg.From, Action = 'Hyperengine-Publish-Template-Response', Data = "", Error = tostring(result) })
            end
          end
        )
      
        Handlers.add("Hyperengine-Unpublish-Template",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-Unpublish-Template"),
          function(msg)
            assert(hyperengine.has_permission(msg.From, "Hyperengine-Unpublish-Template"), "not authorized to unpublish templates")
            local path = msg.Tags.Path or msg.Tags.path
            assert(path, "Path tag is required, got: " .. tostring(path))
            hyperengine.unpublishTemplate(path)
            hyperengine.sync()
            Send({ Target = msg.From, Action = 'Hyperengine-Unpublish-Template-Response', Data = 'OK' })
          end
        )
      
        Handlers.add("Hyperengine-List-Published",
          Handlers.utils.hasMatchingTag("Action", "Hyperengine-List-Published"),
          function(msg)
            local published = hyperengine.listPublished()
            Send({ Target = msg.From, Action = 'Hyperengine-List-Published-Response', Data = json.encode(published) })
          end
        )
      end
      
      if not hyperengine_initialized then
        hyperengine.sync()
        hyperengine_initialized = true
      end
      
      return hyperengine
      
    end
    
    _G.package.loaded["lustache.scanner"] = _loaded_mod_lustache_scanner()
    _G.package.loaded["lustache.context"] = _loaded_mod_lustache_context()
    _G.package.loaded["lustache.renderer"] = _loaded_mod_lustache_renderer()
    _G.package.loaded["lustache"] = _loaded_mod_lustache()
    _G.package.loaded["hyperengine"] = _loaded_mod_hyperengine()
    
    -- Entry point
    -- bundled AO process (registry)
    
    package.preload["ao.shared.a11y"] = function()
      local loaded, err = load([====[-- Simple accessibility & performance lint for page content blocks.
    
    local A11y = {}
    
    local function warn(list, msg)
      table.insert(list, msg)
    end
    
    -- Validate a single block; return warnings appended to provided list.
    local function validate_block(block, warnings, last_heading_level)
      local typ = block.type or block.kind
      if typ == "image" or typ == "hero" then
        if not block.alt or block.alt == "" then
          warn(warnings, "Image block missing alt text")
        end
      elseif typ == "link" then
        if not block.text or block.text == "" then
          warn(warnings, "Link block missing text")
        end
        if block.href and block.href:match "^javascript:" then
          warn(warnings, "Link uses javascript: URI, avoid for accessibility")
        end
      elseif typ == "heading" then
        local level = tonumber(block.level or block.depth or 0) or 0
        if level < 1 or level > 6 then
          warn(warnings, "Heading level must be 1-6")
        elseif last_heading_level and level > last_heading_level + 1 then
          warn(
            warnings,
            string.format("Heading level skips from h%d to h%d", last_heading_level, level)
          )
        end
        return level
      end
      return last_heading_level
    end
    
    ---Validate a page content table (expects blocks array).
    -- Returns ok:boolean, warnings:table
    function A11y.validate_page(content)
      local warnings = {}
      if not content or type(content) ~= "table" then
        return true, warnings
      end
      local blocks = content.blocks or {}
      local last_heading_level = nil
      for _, block in ipairs(blocks) do
        last_heading_level = validate_block(block, warnings, last_heading_level)
      end
      return #warnings == 0, warnings
    end
    
    return A11y
    ]====], "ao.shared.a11y")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.analytics"] = function()
      local loaded, err = load([====[-- Simple analytics/risk/subscription helpers (secretless, future-proof).
    -- Counts via metrics and optionally appends NDJSON to METRICS_LOG.
    
    local cjson = require "cjson"
    local metrics = require "ao.shared.metrics"
    
    local Analytics = {}
    
    local function write_log(ev)
      local path = os.getenv "METRICS_LOG"
      if not path or path == "" then
        return
      end
      local f = io.open(path, "a")
      if not f then
        return
      end
      ev.ts = os.date "!%Y-%m-%dT%H:%M:%SZ"
      f:write(cjson.encode(ev))
      f:write "\n"
      f:close()
    end
    
    function Analytics.page_view(site, path, locale)
      metrics.inc "ao_page_view"
      write_log { event = "page_view", site = site, path = path, locale = locale }
    end
    
    function Analytics.product_view(site, sku, locale)
      metrics.inc "ao_product_view"
      write_log { event = "product_view", site = site, sku = sku, locale = locale }
    end
    
    -- risk event: attrs should already be hashed/obfuscated
    function Analytics.risk_event(kind, attrs)
      metrics.inc "ao_risk_event"
      local ev = attrs or {}
      ev.event = kind or "risk"
      write_log(ev)
    end
    
    function Analytics.subscription_start(site, plan, attrs)
      metrics.inc "ao_subscription_start"
      local ev = attrs or {}
      ev.event = "subscription_start"
      ev.site = site
      ev.plan = plan
      write_log(ev)
    end
    
    function Analytics.subscription_cancel(site, plan, reason, attrs)
      metrics.inc "ao_subscription_cancel"
      metrics.inc "ao_subscription_churn"
      local ev = attrs or {}
      ev.event = "subscription_cancel"
      ev.site = site
      ev.plan = plan
      ev.reason = reason
      write_log(ev)
    end
    
    return Analytics
    ]====], "ao.shared.analytics")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.arweave"] = function()
      local loaded, err = load([====[-- Arweave adapter for publish flow.
    -- Default mode: file-backed mock under arweave/snapshots (deterministic, hash checked).
    -- If ARWEAVE_MODE=mock (default), nothing leaves the machine.
    
    local Ar = {}
    
    local counter = 0
    local manifests = {}
    
    local MODE = os.getenv "ARWEAVE_MODE" or "mock"
    local SNAPSHOT_DIR = os.getenv "ARWEAVE_STORAGE_DIR" or "arweave/snapshots"
    local REQUEST_LOG = os.getenv "ARWEAVE_REQUEST_LOG" or "arweave/manifests"
    local ENDPOINT = os.getenv "ARWEAVE_HTTP_ENDPOINT"
    local API_KEY = os.getenv "ARWEAVE_HTTP_API_KEY"
    local SIGNER = os.getenv "ARWEAVE_HTTP_SIGNER" -- path to key or wallet JSON
    local HTTP_TIMEOUT = tonumber(os.getenv "ARWEAVE_HTTP_TIMEOUT" or "10")
    local HTTP_REAL = os.getenv "ARWEAVE_HTTP_REAL" == "1"
    local HTTP_SIGNER_HEADER = os.getenv "ARWEAVE_HTTP_SIGNER_HEADER" or "X-Arweave-Signer"
    local HTTP_RETRIES = tonumber(os.getenv "ARWEAVE_HTTP_RETRIES" or "3")
    local HTTP_BACKOFF_MS = tonumber(os.getenv "ARWEAVE_HTTP_BACKOFF_MS" or "200")
    local MAX_MANIFEST_BYTES = tonumber(os.getenv "ARWEAVE_MAX_MANIFEST_BYTES" or "262144") -- 256 KiB
    local HTTP_MAX_BODY = tonumber(os.getenv "ARWEAVE_HTTP_MAX_BODY" or "1048576") -- 1 MiB
    local EXPECT_RESPONSE_HASH = os.getenv "ARWEAVE_EXPECT_RESPONSE_HASH"
    local FORCE_ERROR = os.getenv "ARWEAVE_FORCE_ERROR" == "1"
    local RESPONSE_PATTERN = os.getenv "ARWEAVE_RESPONSE_PATTERN" or '^%s*%{"'
    local _, cjson_safe = pcall(require, "cjson.safe")
    local cjson = cjson_safe or require "cjson" -- required dependency
    local schema = require "ao.shared.schema"
    local openssl_ok, openssl = pcall(require, "openssl")
    local sodium_ok, sodium = pcall(require, "sodium")
    if not sodium_ok then
      sodium_ok, sodium = pcall(require, "luasodium")
    end
    
    local function next_tx()
      counter = counter + 1
      return string.format("mock-tx-%06d", counter)
    end
    
    local function ensure_dir(path)
      os.execute(string.format('mkdir -p "%s"', path))
    end
    
    local function bin_to_hex(bytes)
      return (bytes:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end))
    end
    
    local function sha256(str)
      if openssl_ok and openssl.digest then
        local d = openssl.digest.new "sha256"
        d:update(str)
        return bin_to_hex(d:final())
      elseif sodium_ok and sodium.crypto_hash_sha256 then
        return bin_to_hex(sodium.crypto_hash_sha256(str))
      else
        local r = io.popen(
          'printf %s "'
            .. str:gsub('"', '\\"')
            .. '" | openssl dgst -sha256 -binary 2>/dev/null | xxd -p',
          "r"
        )
        if r then
          local out = r:read "*a" or ""
          r:close()
          out = out:gsub("%s+", "")
          if #out > 0 then
            return out
          end
        end
      end
      return nil
    end
    
    local function file_sha256(path)
      local f = io.open(path, "rb")
      if not f then
        return nil
      end
      local content = f:read "*a"
      f:close()
      return sha256(content)
    end
    
    local function has_curl()
      local ok = os.execute "command -v curl >/dev/null 2>&1"
      return ok == true or ok == 0
    end
    
    local function http_post(serialized, tx)
      ensure_dir(REQUEST_LOG)
      local response_path = string.format("%s/%s-response.json", REQUEST_LOG, tx)
      local auth_header = API_KEY and (' -H "Authorization: Bearer ' .. API_KEY .. '"') or ""
      local signer_header = SIGNER and (' -H "' .. HTTP_SIGNER_HEADER .. ": " .. SIGNER .. '"') or ""
      local curl_fmt = table.concat({
        'echo %q | curl -s -o "%s" -w "%%{http_code}"',
        '-H "Content-Type: application/json"%s%s',
        '--max-time %d -X POST "%s" --data-binary @-',
      }, " ")
      local status
      for attempt = 1, HTTP_RETRIES do
        local cmd = string.format(
          curl_fmt,
          serialized,
          response_path,
          auth_header,
          signer_header,
          HTTP_TIMEOUT,
          ENDPOINT or ""
        )
        local pipe = io.popen(cmd, "r")
        if pipe then
          status = pipe:read "*a"
          pipe:close()
          status = status and status:match "(%d+)"
          if status then
            status = tonumber(status)
          end
          if status and status < 500 then
            break
          end
        end
        if attempt < HTTP_RETRIES then
          local jitter = math.random() * 0.5 + 0.75 -- 0.75-1.25x
          os.execute(string.format("sleep %.3f", (HTTP_BACKOFF_MS * jitter) / 1000))
        end
      end
      return status, response_path
    end
    
    local function signer_exists()
      if not SIGNER or SIGNER == "" then
        return true
      end
      local f = io.open(SIGNER, "r")
      if f then
        f:close()
        return true
      end
      return false
    end
    
    local function fallback_checksum(str)
      local sum = 0
      for i = 1, #str do
        sum = (sum + string.byte(str, i)) % 0xFFFFFFFF
      end
      return string.format("%08x", sum)
    end
    
    local function is_array(tbl)
      local i = 0
      for _ in pairs(tbl) do
        i = i + 1
        if tbl[i] == nil then
          return false
        end
      end
      return true
    end
    
    local function sorted_keys(tbl)
      local keys = {}
      for k in pairs(tbl) do
        table.insert(keys, k)
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      return keys
    end
    
    local function json_encode(value)
      local t = type(value)
      if t == "nil" then
        return "null"
      end
      if t == "boolean" then
        return value and "true" or "false"
      end
      if t == "number" then
        return tostring(value)
      end
      if t == "string" then
        return string.format("%q", value)
      end
      if t == "table" then
        if is_array(value) then
          local parts = {}
          for _, v in ipairs(value) do
            table.insert(parts, json_encode(v))
          end
          return "[" .. table.concat(parts, ",") .. "]"
        else
          local parts = {}
          for _, k in ipairs(sorted_keys(value)) do
            local v = value[k]
            table.insert(parts, string.format("%q:%s", k, json_encode(v)))
          end
          return "{" .. table.concat(parts, ",") .. "}"
        end
      end
      return '"<unsupported>"'
    end
    
    local function persist_manifest(tx, content)
      ensure_dir(SNAPSHOT_DIR)
      local path = SNAPSHOT_DIR .. "/" .. tx .. ".json"
      local f = io.open(path, "w")
      if f then
        f:write(content)
        f:close()
      end
    end
    
    -- Stores a snapshot payload and returns a manifest transaction id and hash.
    function Ar.put_snapshot(payload)
      local tx = next_tx()
      local serialized = json_encode(payload)
      if MAX_MANIFEST_BYTES and #serialized > MAX_MANIFEST_BYTES then
        return nil, "too_large"
      end
      local hash = sha256(serialized) or fallback_checksum(serialized)
    
      manifests[tx] = {
        payload = payload,
        hash = hash,
        storedAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
      }
    
      if MODE == "mock" then
        persist_manifest(tx, serialized)
      end
    
      return tx, hash
    end
    
    function Ar.get_snapshot(tx)
      return manifests[tx]
    end
    
    function Ar.verify_snapshot(tx, expected_hash)
      local m = manifests[tx]
      if not m then
        return false, "not_found"
      end
      if expected_hash and m.hash ~= expected_hash then
        return false, "hash_mismatch"
      end
      return true
    end
    
    -- HTTP mode placeholder: log outbound request; real network disabled here.
    local function log_request(tx, payload, hash)
      ensure_dir(REQUEST_LOG)
      local path = string.format("%s/%s-request.json", REQUEST_LOG, tx)
      local f = io.open(path, "w")
      if f then
        f:write(json_encode { tx = tx, hash = hash, payload = payload, mode = MODE })
        f:close()
      end
    end
    
    if MODE == "http" then
      -- Simulated HTTP call: writes request + simulated response status to manifests log.
      -- Still offline/off-chain; safe for local runs.
      function Ar.put_snapshot(payload)
        local tx = next_tx()
        local serialized = json_encode(payload)
        if MAX_MANIFEST_BYTES and #serialized > MAX_MANIFEST_BYTES then
          return nil, "too_large"
        end
        local hash = sha256(serialized) or fallback_checksum(serialized)
        local httpStatus, response_path
        if FORCE_ERROR then
          httpStatus = 500
        elseif HTTP_REAL and ENDPOINT and has_curl() and os.getenv "ARWEAVE_HTTP_DRYRUN" ~= "1" then
          if not signer_exists() then
            log_request(tx, {
              endpoint = ENDPOINT or "<missing-endpoint>",
              apiKey = API_KEY and "<redacted>",
              signer = SIGNER or "<missing>",
              timeout = HTTP_TIMEOUT,
              body = payload,
              simulated = true,
              error = "signer_missing",
            }, hash)
            return tx, hash
          end
          httpStatus, response_path = http_post(serialized, tx)
        else
          -- offline simulated response body so schema validation/path logic still runs
          ensure_dir(REQUEST_LOG)
          response_path = string.format("%s/%s-response.json", REQUEST_LOG, tx)
          local body = os.getenv "ARWEAVE_HTTP_SIM_BODY"
            or string.format('{"status":"ok","tx":"%s"}', tx)
          local f = io.open(response_path, "w")
          if f then
            f:write(body)
            f:close()
          end
          httpStatus = tonumber(os.getenv "ARWEAVE_HTTP_SIM_STATUS" or "200")
        end
        local signerHash = SIGNER and file_sha256(SIGNER) or nil
        if httpStatus and httpStatus >= 400 then
          log_request(tx, { error = "http_error", status = httpStatus })
          return nil, "http_error"
        end
        if response_path then
          local f = io.open(response_path, "r")
          if f then
            local body = f:read "*a" or ""
            f:close()
            if #body == 0 then
              log_request(tx, { warning = "empty_response" })
            elseif HTTP_MAX_BODY and #body > HTTP_MAX_BODY then
              log_request(tx, { error = "response_too_large", size = #body })
              return nil, "http_response_too_large"
            else
              if RESPONSE_PATTERN and not body:match(RESPONSE_PATTERN) then
                log_request(tx, { warning = "response_unexpected_pattern" })
                return nil, "http_response_invalid"
              end
              local parsed = cjson.decode(body)
              if not parsed then
                return nil, "http_response_invalid_json"
              end
              local ok_schema, err_schema = schema.validate("arweaveResponse", parsed)
              if not ok_schema then
                log_request(tx, { warning = "response_schema_invalid", errors = err_schema })
                return nil, "http_response_schema_invalid"
              end
              local resp_hash = sha256(body)
              if not resp_hash then
                log_request(tx, { warning = "response_hash_failed" })
              else
                log_request(tx, { responseHash = resp_hash })
                if EXPECT_RESPONSE_HASH and resp_hash ~= EXPECT_RESPONSE_HASH then
                  return nil, "response_hash_mismatch"
                end
              end
            end
          end
        end
        log_request(tx, {
          endpoint = ENDPOINT or "<missing-endpoint>",
          apiKey = API_KEY and "<redacted>",
          signer = SIGNER and "<redacted>",
          signerHash = signerHash,
          timeout = HTTP_TIMEOUT,
          body = payload,
          simulated = not HTTP_REAL,
          httpStatus = httpStatus,
          responsePath = response_path,
        }, hash)
        return tx, hash
      end
    end
    
    -- Expose for tests
    Ar._manifests = manifests
    
    return Ar
    ]====], "ao.shared.arweave")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.assets"] = function()
      local loaded, err = load([====[-- Asset helpers: generate responsive variants and minimal CDN invalidation hooks.
    
    local Assets = {}
    
    local DEFAULT_SIZES = { 320, 640, 960, 1280, 1920 }
    local DEFAULT_FORMATS = { "avif", "webp", "jpg" }
    
    local function normalize_formats(formats)
      if not formats or #formats == 0 then
        return DEFAULT_FORMATS
      end
      local out = {}
      local seen = {}
      for _, f in ipairs(formats) do
        local fmt = tostring(f):lower()
        if not seen[fmt] then
          table.insert(out, fmt)
          seen[fmt] = true
        end
      end
      return out
    end
    
    local function normalize_sizes(sizes)
      if not sizes or #sizes == 0 then
        return DEFAULT_SIZES
      end
      local out = {}
      for _, s in ipairs(sizes) do
        local n = tonumber(s)
        if n and n > 0 then
          table.insert(out, math.floor(n))
        end
      end
      table.sort(out)
      return out
    end
    
    local function build_url(base_url, path)
      if not base_url or base_url == "" then
        return path
      end
      if base_url:sub(-1) == "/" then
        base_url = base_url:sub(1, -2)
      end
      if path:sub(1, 1) ~= "/" then
        path = "/" .. path
      end
      return base_url .. path
    end
    
    ---Generate responsive variants for an image using a deterministic URL pattern.
    -- The pattern is: {base}/{width}w/{basename}.{format}
    function Assets.build_image_variants(src, opts)
      opts = opts or {}
      local sizes = normalize_sizes(opts.sizes)
      local formats = normalize_formats(opts.formats)
      local base_url = opts.base_url or os.getenv "ASSET_BASE_URL" or "/assets"
    
      local basename = src:gsub("^.*/", "")
      local variants = {}
      local srcset = {}
    
      for _, fmt in ipairs(formats) do
        srcset[fmt] = {}
        for _, w in ipairs(sizes) do
          local path = string.format("%dw/%s.%s", w, basename, fmt)
          local url = build_url(base_url, path)
          table.insert(srcset[fmt], string.format("%s %dw", url, w))
          table.insert(variants, { width = w, format = fmt, url = url })
        end
        srcset[fmt] = table.concat(srcset[fmt], ", ")
      end
    
      return {
        src = build_url(base_url, basename),
        sizes = sizes,
        formats = formats,
        variants = variants,
        srcset = srcset,
        loading = "lazy",
        placeholder = "blur",
      }
    end
    
    -- Lightweight CDN purge hook; caller passes relative or absolute paths.
    function Assets.cdn_invalidate(paths)
      if type(paths) ~= "table" or #paths == 0 then
        return { purged = 0 }
      end
      local purged = 0
      local endpoint = os.getenv "CDN_PURGE_URL"
      for _, path in ipairs(paths) do
        if endpoint and endpoint ~= "" then
          os.execute(string.format("curl -s -X PURGE %s%s >/dev/null 2>&1", endpoint, path))
        else
          -- fallback: no-op echo
          os.execute(string.format('echo "PURGE %s" >/dev/null', path))
        end
        purged = purged + 1
      end
      return { purged = purged }
    end
    
    return Assets
    ]====], "ao.shared.assets")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.audit"] = function()
      local loaded, err = load([====[-- Append-only audit stub for local testing.
    
    local Audit = {}
    local records = {}
    local LOG_DIR = os.getenv "AUDIT_LOG_DIR" or "arweave/manifests"
    local MAX_IN_MEMORY = tonumber(os.getenv "AUDIT_MAX_RECORDS" or "1000")
    local FORMAT = os.getenv "AUDIT_FORMAT" or "line" -- line | ndjson
    local ROTATE_MAX = tonumber(os.getenv "AUDIT_ROTATE_MAX" or "1048576") -- bytes
    local RETAIN_FILES = tonumber(os.getenv "AUDIT_RETAIN_FILES" or "10") -- number of rotated files per stream
    
    local function ensure_dir(path)
      os.execute(string.format('mkdir -p "%s"', path))
    end
    
    local function is_array(tbl)
      local i = 0
      for _ in pairs(tbl) do
        i = i + 1
        if tbl[i] == nil then
          return false
        end
      end
      return true
    end
    
    local function json_encode(value)
      local t = type(value)
      if t == "nil" then
        return "null"
      end
      if t == "boolean" then
        return value and "true" or "false"
      end
      if t == "number" then
        return tostring(value)
      end
      if t == "string" then
        return string.format("%q", value)
      end
      if t == "table" then
        if is_array(value) then
          local parts = {}
          for _, v in ipairs(value) do
            table.insert(parts, json_encode(v))
          end
          return "[" .. table.concat(parts, ",") .. "]"
        else
          local parts = {}
          for k, v in pairs(value) do
            table.insert(parts, string.format("%q:%s", k, json_encode(v)))
          end
          return "{" .. table.concat(parts, ",") .. "}"
        end
      end
      return '"<unsupported>"'
    end
    
    local lfs_ok, lfs = pcall(require, "lfs")
    
    local function rotate_if_needed(path)
      if not path or path == "" then
        return
      end
      local f = io.open(path, "r")
      if not f then
        return
      end
      local content = f:read "*a"
      f:close()
      if #content >= ROTATE_MAX then
        local rotated = path .. "." .. os.date "!%Y%m%d%H%M%S"
        os.rename(path, rotated)
        if lfs_ok then
          -- retention
          local dir, file = path:match "(.+)/([^/]+)$"
          local prefix = file .. "."
          local rotated_files = {}
          for rfile in lfs.dir(dir) do
            if rfile:find("^" .. prefix) then
              table.insert(rotated_files, dir .. "/" .. rfile)
            end
          end
          table.sort(rotated_files, function(a, b)
            return a > b
          end) -- newest first (lexicographic on timestamp suffix)
          for i = RETAIN_FILES + 1, #rotated_files do
            os.remove(rotated_files[i])
          end
        end
      end
    end
    
    function Audit.append(entry)
      if os.getenv "AUDIT_DISABLE" == "1" then
        return true
      end
      if not entry.ts then
        entry.ts = os.date "!%Y-%m-%dT%H:%M:%SZ"
      end
      table.insert(records, entry)
      if #records > MAX_IN_MEMORY then
        table.remove(records, 1)
      end
      if LOG_DIR then
        ensure_dir(LOG_DIR)
        local path = string.format("%s/audit.log", LOG_DIR)
        rotate_if_needed(path)
        local f = io.open(path, "a")
        if f then
          if FORMAT == "ndjson" then
            f:write(json_encode(entry), "\n")
          else
            f:write(tostring(entry.action or "event"), " ", json_encode(entry), "\n")
          end
          f:close()
        end
      end
    end
    
    -- Helper to record a normalized event
    -- fields: process, action, requestId, actorRole, siteId, resultCode
    function Audit.record(process, action, msg, resp, extra)
      local entry = {
        process = process,
        action = action,
        requestId = msg and msg["Request-Id"],
        actorRole = msg and (msg["Actor-Role"] or msg.actorRole),
        siteId = msg and (msg["Site-Id"] or msg.siteId),
        status = resp and resp.status,
        resultCode = resp and resp.code or resp and resp.status,
      }
      if extra then
        for k, v in pairs(extra) do
          entry[k] = v
        end
      end
      Audit.append(entry)
      -- optional per-process log
      if LOG_DIR and process then
        local path = string.format("%s/audit-%s.log", LOG_DIR, process)
        rotate_if_needed(path)
        local f = io.open(path, "a")
        if f then
          if FORMAT == "ndjson" then
            f:write(json_encode(entry), "\n")
          else
            f:write(tostring(entry.action or "event"), " ", json_encode(entry), "\n")
          end
          f:close()
        end
      end
    end
    
    function Audit.all()
      return records
    end
    
    function Audit.log_path()
      return LOG_DIR and (LOG_DIR .. "/audit.log") or nil
    end
    
    function Audit.process_log_path(process)
      if not LOG_DIR or not process then
        return nil
      end
      return string.format("%s/audit-%s.log", LOG_DIR, process)
    end
    
    function Audit._clear()
      records = {}
    end
    
    return Audit
    ]====], "ao.shared.audit")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.auth"] = function()
      local loaded, err = load([====[-- Shared auth utilities: signature verification and role checks.
    -- AO environment is expected to verify signatures; here we keep role/allowlist helpers.
    
    local jwt_ok, jwt = pcall(require, "ao.shared.jwt")
    local metrics_ok, metrics = pcall(require, "ao.shared.metrics")
    
    local Auth = {}
    local os_time = os.time
    
    local NONCE_TTL = tonumber(os.getenv "AUTH_NONCE_TTL_SECONDS" or "300")
    local NONCE_MAX = tonumber(os.getenv "AUTH_NONCE_MAX_ENTRIES" or "2048")
    local NONCE_SQLITE = os.getenv "AUTH_NONCE_SQLITE"
    local REQUIRE_NONCE = os.getenv "AUTH_REQUIRE_NONCE" ~= "0" -- default ON
    local REQUIRE_SIGNATURE = os.getenv "AUTH_REQUIRE_SIGNATURE" ~= "0" -- default ON
    local REQUIRE_TS = os.getenv "AUTH_REQUIRE_TIMESTAMP" ~= "0"
    local TS_DRIFT = tonumber(os.getenv "AUTH_MAX_CLOCK_SKEW" or "300")
    local RL_WINDOW = tonumber(os.getenv "AUTH_RATE_LIMIT_WINDOW_SECONDS" or "60")
    local RL_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_REQUESTS" or "200")
    local RL_SITE_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_SITE" or "200")
    local RL_CALLER_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_CALLER" or "200")
    local RL_STATE_FILE = os.getenv "AUTH_RATE_LIMIT_FILE"
    local RL_SQLITE = os.getenv "AUTH_RATE_LIMIT_SQLITE"
    local SIG_SECRET = os.getenv "AUTH_SIGNATURE_SECRET"
    local SIG_PUBLIC = os.getenv "AUTH_SIGNATURE_PUBLIC"
    local SIG_TYPE = os.getenv "AUTH_SIGNATURE_TYPE" or "hmac" -- hmac | ed25519
    local JWT_SECRET = os.getenv "AUTH_JWT_HS_SECRET"
    local REQUIRE_JWT = os.getenv "AUTH_REQUIRE_JWT" == "1"
    local DEVICE_TOKEN = os.getenv "AUTH_DEVICE_TOKEN"
    local REQUIRE_DEVICE = os.getenv "AUTH_REQUIRE_DEVICE_TOKEN" == "1"
    local REJECT_PLACEHOLDERS = os.getenv "ALLOW_PLACEHOLDER_SECRETS" ~= "1"
    local PLACEHOLDER_SECRETS = {
      ["changeme-jwt-hmac"] = true,
      ["changeme-outbox-hmac"] = true,
      ["changeme-trust-hmac"] = true,
      ["changeme"] = true,
      ["change-me"] = true,
    }
    local openssl_ok, openssl = pcall(require, "openssl")
    local sodium_ok, sodium = pcall(require, "sodium")
    if not sodium_ok then
      sodium_ok, sodium = pcall(require, "luasodium")
    end
    local ed25519_ok, ed25519 = pcall(require, "ed25519") -- pure-lua (MIT) if installed
    local sqlite_ok, sqlite = pcall(require, "lsqlite3")
    local SHELL_FALLBACK = os.getenv "AUTH_ALLOW_SHELL_FALLBACK" == "1" -- default now off
    local json_ok, json = pcall(require, "cjson.safe")
    local FLAGS_FILE = os.getenv "AUTH_RESOLVER_FLAGS_FILE" or os.getenv "AO_FLAGS_PATH"
    
    local nonce_store = {}
    local nonce_db
    local nonce_db_loaded = false
    local rate_store = {}
    local rate_db_loaded = false
    local resolver_flags = {}
    
    -- load persisted rate store (simple CSV key,count,reset)
    if RL_STATE_FILE then
      local f = io.open(RL_STATE_FILE, "r")
      if f then
        for line in f:lines() do
          local key, count, reset = line:match "^([^,]+),(%d+),(%d+)"
          if key and count and reset then
            rate_store[key] = { count = tonumber(count), reset = tonumber(reset) }
          end
        end
        f:close()
      end
    end
    
    local SIGNATURE_EXCLUDE_KEYS = {
      Signature = true,
      signature = true,
      ["Signature-Ref"] = true,
    }
    
    local function contains(list, value)
      for _, v in ipairs(list) do
        if v == value then
          return true
        end
      end
      return false
    end
    
    local function hex_encode(bytes)
      if not bytes then
        return nil
      end
      if openssl_ok and openssl.hex then
        return openssl.hex(bytes)
      end
      if sodium_ok then
        if sodium.to_hex then
          return sodium.to_hex(bytes)
        end
        if sodium.bin2hex then
          return sodium.bin2hex(bytes)
        end
      end
      return (bytes:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end))
    end
    
    local function sorted_pairs(tbl)
      local keys = {}
      for k in pairs(tbl) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
      local i = 0
      return function()
        i = i + 1
        local key = keys[i]
        if key then
          return key, tbl[key]
        end
      end
    end
    
    local function canonical_value(val)
      local t = type(val)
      if t == "table" then
        local parts = {}
        for k, v in sorted_pairs(val) do
          parts[#parts + 1] = tostring(k) .. "=" .. canonical_value(v)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      elseif t == "boolean" then
        return val and "true" or "false"
      elseif t == "number" then
        return tostring(val)
      elseif t == "string" then
        return val
      else
        return ""
      end
    end
    
    local function canonical_payload(msg)
      if type(msg) ~= "table" then
        return ""
      end
      local cleaned = {}
      for k, v in pairs(msg) do
        if not SIGNATURE_EXCLUDE_KEYS[k] then
          cleaned[k] = v
        end
      end
      return canonical_value(cleaned)
    end
    
    local function extract_bearer(msg)
      if msg.jwt then
        return msg.jwt
      end
      if msg.JWT then
        return msg.JWT
      end
      if msg.token then
        return msg.token
      end
      local authz = msg.Authorization or msg.authorization or msg.auth
      if authz and type(authz) == "string" then
        return (authz:gsub("^%s*[Bb]earer%s+", ""))
      end
    end
    
    local function placeholder_secret(secret)
      if not REJECT_PLACEHOLDERS then
        return false
      end
      if not secret or secret == "" then
        return false
      end
      local lower = tostring(secret):lower()
      if PLACEHOLDER_SECRETS[lower] then
        return true
      end
      return lower:find "change%-me" or lower:find "changeme"
    end
    
    function Auth.consume_jwt(msg)
      if not JWT_SECRET or JWT_SECRET == "" then
        return true
      end
      if placeholder_secret(JWT_SECRET) then
        return false, "placeholder_jwt_secret"
      end
      if not jwt_ok then
        return not REQUIRE_JWT, "jwt_module_missing"
      end
      local token = extract_bearer(msg)
      if not token or token == "" then
        if REQUIRE_JWT then
          return false, "missing_jwt"
        end
        return true
      end
      local ok, claims = jwt.verify_hs256(token, JWT_SECRET)
      if not ok then
        return false, claims or "jwt_invalid"
      end
      if claims.exp and os_time() > claims.exp then
        return false, "jwt_expired"
      end
      msg["Actor-Id"] = msg["Actor-Id"] or claims.sub or claims.actor
      msg["Actor-Role"] = msg["Actor-Role"] or claims.role
      msg["Tenant"] = msg["Tenant"] or claims.tenant
      msg.Nonce = msg.Nonce or claims.nonce
      msg.jwt_claims = claims
      return true
    end
    
    -- Accepts either dash or camel case field names for flexibility with gateways.
    local function extract_role(msg)
      return msg["Actor-Role"] or msg.actorRole or msg.role
    end
    
    local function prune_nonces()
      local now = os_time()
      local count = 0
      for k, v in pairs(nonce_store) do
        local exp = v.exp or v
        if exp < now then
          nonce_store[k] = nil
        else
          count = count + 1
        end
      end
      if count > NONCE_MAX then
        -- drop oldest
        local oldest_key, oldest_val
        for k, v in pairs(nonce_store) do
          if not oldest_val or v < oldest_val then
            oldest_val = v
            oldest_key = k
          end
        end
        if oldest_key then
          nonce_store[oldest_key] = nil
        end
      end
    end
    
    local function load_nonce_db()
      if nonce_db_loaded or not NONCE_SQLITE then
        return
      end
      if not sqlite_ok then
        return false, "nonce_sqlite_missing"
      end
      nonce_db = sqlite.open(NONCE_SQLITE)
      if not nonce_db then
        return false, "nonce_sqlite_open_failed"
      end
      nonce_db:exec "CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, exp INT, rid TEXT)"
      nonce_db_loaded = true
      return true
    end
    
    local function nonce_db_get(nonce)
      if not nonce_db then
        return nil
      end
      local stmt = nonce_db:prepare "SELECT exp,rid FROM nonces WHERE nonce=?"
      stmt:bind_values(nonce)
      local row = stmt:step() == sqlite.ROW and { exp = stmt:get_value(0), rid = stmt:get_value(1) }
        or nil
      stmt:finalize()
      return row
    end
    
    local function nonce_db_put(nonce, exp, rid)
      if not nonce_db then
        return
      end
      local stmt = nonce_db:prepare "INSERT OR REPLACE INTO nonces (nonce, exp, rid) VALUES (?, ?, ?)"
      stmt:bind_values(nonce, exp, rid)
      stmt:step()
      stmt:finalize()
    end
    
    local function nonce_db_cleanup(now)
      if nonce_db then
        nonce_db:exec(string.format("DELETE FROM nonces WHERE exp < %d", now))
      end
    end
    
    function Auth.require_nonce(msg)
      prune_nonces()
      local nonce = msg.Nonce or msg.nonce
      if not nonce then
        if REQUIRE_NONCE then
          return false, "missing_nonce"
        end
        return true
      end
    
      local now = os_time()
      local function memo_seen(entry)
        if entry and entry.exp and entry.exp >= now then
          return entry
        end
      end
    
      local seen = memo_seen(nonce_store[nonce])
    
      if not seen and NONCE_SQLITE then
        local ok_db, err_db = load_nonce_db()
        if ok_db == false then
          return false, err_db
        end
        seen = memo_seen(nonce_db_get(nonce))
      end
    
      if seen then
        if seen.rid and seen.rid == msg["Request-Id"] then
          return true
        end
        return false, "replay_nonce"
      end
    
      local record = { exp = now + NONCE_TTL, rid = msg["Request-Id"] }
      nonce_store[nonce] = record
      if NONCE_SQLITE and nonce_db_loaded then
        nonce_db_put(nonce, record.exp, record.rid)
        nonce_db_cleanup(now)
      end
      prune_nonces()
      return true
    end
    
    local function require_timestamp(msg)
      if not REQUIRE_TS then
        return true
      end
      local ts = msg.ts or msg.timestamp or msg["X-Timestamp"]
      if not ts then
        return false, "missing_timestamp"
      end
      ts = tonumber(ts)
      if not ts then
        return false, "invalid_timestamp"
      end
      local now = os_time()
      if math.abs(now - ts) > TS_DRIFT then
        return false, "timestamp_skew"
      end
      return true
    end
    
    function Auth.require_signature(msg)
      local sig = msg.Signature or msg.signature or msg["Signature-Ref"]
      if not sig then
        if REQUIRE_SIGNATURE then
          return false, "missing_signature"
        end
        return true
      end
    
      local target = canonical_payload(msg)
    
      if SIG_TYPE == "ed25519" and SIG_PUBLIC then
        if ed25519_ok and ed25519.verify then
          local pub = assert(io.open(SIG_PUBLIC, "rb")):read "*a"
          local raw_sig = ed25519.fromhex and ed25519.fromhex(sig) or sig
          if raw_sig and ed25519.verify(raw_sig, target, pub) then
            return true
          end
        end
        if sodium_ok and sodium.crypto_sign_verify_detached then
          local pub = assert(io.open(SIG_PUBLIC, "rb")):read "*a"
          local raw_sig
          if sodium.from_hex then
            raw_sig = sodium.from_hex(sig)
          else
            local bytes = {}
            for byte in sig:gmatch "%x%x" do
              bytes[#bytes + 1] = string.char(tonumber(byte, 16))
            end
            raw_sig = table.concat(bytes)
          end
          if raw_sig and sodium.crypto_sign_verify_detached(raw_sig, target, pub) then
            return true
          end
        end
        if openssl_ok and openssl.pkey and openssl.hex then
          local pub_pem = assert(io.open(SIG_PUBLIC, "r")):read "*a"
          local pkey = openssl.pkey.read(pub_pem, true, "public")
          local raw_sig = openssl.hex(sig)
          local ok, _ = pkey:verify(raw_sig, target, "NONE")
          if ok then
            return true
          end
        end
        if SHELL_FALLBACK then
          local tmp = os.tmpname()
          local f = io.open(tmp, "w")
          if f then
            f:write(target)
            f:close()
          end
          local cmd = string.format(
            "openssl pkeyutl -verify -pubin -inkey %q -rawin -in %q -sigfile %q 2>/dev/null",
            SIG_PUBLIC,
            tmp,
            tmp .. ".sig"
          )
          local sf = io.open(tmp .. ".sig", "w")
          if sf then
            sf:write(sig)
            sf:close()
          end
          local ok = os.execute(cmd)
          os.remove(tmp)
          os.remove(tmp .. ".sig")
          if ok == true or ok == 0 then
            return true
          end
        end
        return false, "bad_signature"
      else
        if not SIG_SECRET then
          return not REQUIRE_SIGNATURE, REQUIRE_SIGNATURE and "missing_signature_secret" or nil
        end
        local function canonical_key(secret)
          if not secret then
            return nil
          end
          if #secret == 32 then
            return secret
          end
          if #secret > 32 then
            return secret:sub(1, 32)
          end
          return secret .. string.rep("\0", 32 - #secret)
        end
        if openssl_ok and openssl.hmac then
          local raw = openssl.hmac.digest("sha256", target, SIG_SECRET, true)
          if not raw then
            return false, "sig_verify_failed"
          end
          local hex = hex_encode(raw)
          if hex:lower() ~= tostring(sig):lower() then
            return false, "bad_signature"
          end
          return true
        elseif sodium_ok and sodium.crypto_auth then
          local key = canonical_key(SIG_SECRET)
          local tag = sodium.crypto_auth(target, key)
          local hex = hex_encode(tag)
          if hex:lower() ~= tostring(sig):lower() then
            return false, "bad_signature"
          end
          return true
        else
          -- Fail closed when signature verification is required but no crypto backend is available.
          return false, "sig_backend_missing"
        end
      end
    end
    
    function Auth.verify_outbox_hmac(msg)
      local secret = os.getenv "OUTBOX_HMAC_SECRET"
      if not secret or secret == "" then
        return true
      end
      if placeholder_secret(secret) then
        return false, "placeholder_outbox_hmac_secret"
      end
      local provided = msg.hmac or msg.Hmac
      if not provided then
        return false, "missing_outbox_hmac"
      end
      local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
      if not crypto_ok then
        return false, "crypto_missing"
      end
      local payload = (msg["Site-Id"] or "")
        .. "|"
        .. (msg["Page-Id"] or msg["Order-Id"] or "")
        .. "|"
        .. (msg.Version or msg["Manifest-Tx"] or msg.Amount or "")
      local expected = crypto.hmac_sha256_hex(payload, secret)
      if not expected or expected:lower() ~= tostring(provided):lower() then
        return false, "outbox_hmac_mismatch"
      end
      return true
    end
    
    local function rate_key(msg)
      local site = msg["Site-Id"] or "global"
      local actor = msg.Subject or msg["Actor-Id"] or msg["Actor-Role"] or "anon"
      return site .. ":" .. actor
    end
    
    local function prune_rate()
      local now = os_time()
      for k, v in pairs(rate_store) do
        if v.reset < now then
          rate_store[k] = nil
        end
      end
    end
    
    local function load_rate_store_sqlite()
      if not RL_SQLITE or not sqlite_ok or rate_db_loaded then
        return
      end
      Auth._db = sqlite.open(RL_SQLITE)
      Auth._db:exec "CREATE TABLE IF NOT EXISTS rate (k TEXT PRIMARY KEY, count INT, reset INT)"
      for row in Auth._db:nrows "SELECT k,count,reset FROM rate" do
        rate_store[row.k] =
          { count = tonumber(row.count) or 0, reset = tonumber(row.reset) or os_time() }
      end
      rate_db_loaded = true
    end
    
    function Auth.check_rate_limit(msg)
      load_rate_store_sqlite()
      prune_rate()
      local key = rate_key(msg)
      local now = os_time()
      local bucket = rate_store[key] or { count = 0, reset = now + RL_WINDOW }
      bucket.count = bucket.count + 1
      if bucket.reset < now then
        bucket.count = 1
        bucket.reset = now + RL_WINDOW
      end
      rate_store[key] = bucket
      if bucket.count > RL_MAX then
        if metrics_ok and metrics.counter then
          metrics.counter("ao.auth.rate_global_block", 1)
        end
        return false, "rate_limited"
      end
    
      -- per-site cap
      if RL_SITE_MAX and RL_SITE_MAX > 0 and msg["Site-Id"] then
        local site_key = "site:" .. msg["Site-Id"]
        local s = rate_store[site_key] or { count = 0, reset = now + RL_WINDOW }
        if s.reset < now then
          s.count = 0
          s.reset = now + RL_WINDOW
        end
        s.count = s.count + 1
        rate_store[site_key] = s
        if s.count > RL_SITE_MAX then
          if metrics_ok and metrics.counter then
            metrics.counter("ao.auth.rate_site_block", 1)
          end
          return false, "rate_limited_site"
        end
      end
    
      -- per-caller cap (gateway/worker)
      if RL_CALLER_MAX and RL_CALLER_MAX > 0 and msg["X-Caller"] then
        local caller_key = "caller:" .. tostring(msg["X-Caller"])
        local c = rate_store[caller_key] or { count = 0, reset = now + RL_WINDOW }
        if c.reset < now then
          c.count = 0
          c.reset = now + RL_WINDOW
        end
        c.count = c.count + 1
        rate_store[caller_key] = c
        if c.count > RL_CALLER_MAX then
          if metrics_ok and metrics.counter then
            metrics.counter("ao.auth.rate_caller_block", 1)
          end
          return false, "rate_limited_caller"
        end
      end
      if metrics_ok and metrics.gauge then
        metrics.gauge(
          "ao.auth.rate_buckets",
          (function()
            local n = 0
            for _ in pairs(rate_store) do
              n = n + 1
            end
            return n
          end)()
        )
      end
      if RL_SQLITE and sqlite_ok then
        if not Auth._db then
          Auth._db = sqlite.open(RL_SQLITE)
          Auth._db:exec "CREATE TABLE IF NOT EXISTS rate (k TEXT PRIMARY KEY, count INT, reset INT)"
        end
        local stmt = Auth._db:prepare "INSERT OR REPLACE INTO rate (k,count,reset) VALUES (?, ?, ?)"
        stmt:bind_values(key, bucket.count, bucket.reset)
        stmt:step()
        stmt:finalize()
      elseif RL_STATE_FILE then
        local f = io.open(RL_STATE_FILE, "w")
        if f then
          for rk, rv in pairs(rate_store) do
            f:write(string.format("%s,%d,%d\n", rk, rv.count, rv.reset))
          end
          f:close()
        end
      end
      return true
    end
    
    function Auth.require_role(msg, allowed_roles)
      if not allowed_roles or #allowed_roles == 0 then
        return true
      end
      local role = extract_role(msg)
      if not role then
        return false, "missing_role"
      end
      if not contains(allowed_roles, role) then
        return false, "forbidden_role"
      end
      return true
    end
    
    -- Convenience: pick allowlist by action map { action = {roles...} }
    function Auth.require_role_for_action(msg, policy_table)
      local roles = policy_table[msg.Action]
      if not roles then
        return true
      end
      return Auth.require_role(msg, roles)
    end
    
    local function load_resolver_flags()
      if not FLAGS_FILE or FLAGS_FILE == "" or not json_ok then
        return
      end
      local f = io.open(FLAGS_FILE, "r")
      if not f then
        return
      end
      local tmp = {}
      for line in f:lines() do
        local obj = json.decode(line)
        if obj and obj.resolverId and obj.flag then
          tmp[obj.resolverId] = obj
        end
      end
      f:close()
      resolver_flags = tmp
    end
    
    local function check_resolver_flag(msg)
      if not FLAGS_FILE then
        return true
      end
      local rid = msg["Resolver-Id"] or msg.ResolverId or msg.resolverId or msg.resolver
      if not rid then
        return true
      end
      load_resolver_flags()
      local entry = resolver_flags[rid]
      if not entry then
        return true
      end
      if entry.flag == "blocked" then
        return false, "resolver_blocked"
      elseif entry.flag == "suspicious" then
        local action = msg.Action or ""
        if action:match "^[Gg]et" or action:match "^[Ll]ist" then
          return true
        end
        return false, "resolver_suspicious_readonly"
      end
      return true
    end
    
    local function require_device_token(msg)
      local token = msg["Device-Token"] or msg.deviceToken or msg.device_token or msg.device
      if not token or token == "" then
        if REQUIRE_DEVICE then
          return false, "missing_device_token"
        end
        return true
      end
      if DEVICE_TOKEN and DEVICE_TOKEN ~= "" then
        if token ~= DEVICE_TOKEN then
          return false, "device_token_mismatch"
        end
      end
      return true
    end
    
    -- Combined security gate used by routes
    function Auth.enforce(msg)
      local ok_jwt, err_jwt = Auth.consume_jwt(msg)
      if not ok_jwt then
        return false, err_jwt
      end
      local ok_nonce, err_nonce = Auth.require_nonce(msg)
      if not ok_nonce then
        return false, err_nonce
      end
      local ok_ts, err_ts = require_timestamp(msg)
      if not ok_ts then
        return false, err_ts
      end
      local ok_sig, err_sig = Auth.require_signature(msg)
      if not ok_sig then
        return false, err_sig
      end
      local ok_flag, err_flag = check_resolver_flag(msg)
      if not ok_flag then
        return false, err_flag
      end
      local ok_dev, err_dev = require_device_token(msg)
      if not ok_dev then
        return false, err_dev
      end
      local ok_rl, err_rl = Auth.check_rate_limit(msg)
      if not ok_rl then
        return false, err_rl
      end
      return true
    end
    
    return Auth
    ]====], "ao.shared.auth")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.codec"] = function()
      local loaded, err = load([====[-- Shared codecs and response normalization.
    
    local Codec = {}
    
    function Codec.ok(payload)
      return {
        status = "OK",
        payload = payload or {},
      }
    end
    
    function Codec.error(code, message, meta)
      return {
        status = "ERROR",
        code = code,
        message = message,
        meta = meta,
      }
    end
    
    function Codec.missing_tags(missing)
      return Codec.error("MISSING_TAGS", "Required tags are missing", { missing = missing })
    end
    
    function Codec.unknown_action(action)
      return Codec.error("UNKNOWN_ACTION", "Unsupported action", { action = action })
    end
    
    function Codec.not_found(resource)
      return Codec.error("NOT_FOUND", resource .. " not found", { resource = resource })
    end
    
    function Codec.not_implemented(action)
      return Codec.error("NOT_IMPLEMENTED", "Handler not implemented", { action = action })
    end
    
    return Codec
    ]====], "ao.shared.codec")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.export"] = function()
      local loaded, err = load([====[-- PII-scrubbing append-only export for WeaveDB/Arweave bundling.
    -- Enabled when AO_WEAVEDB_EXPORT_PATH (or WRITE_OUTBOX_EXPORT_PATH) is set.
    
    local Export = {}
    
    local path = os.getenv "AO_WEAVEDB_EXPORT_PATH" or os.getenv "WRITE_OUTBOX_EXPORT_PATH"
    local json_ok, cjson = pcall(require, "cjson.safe")
    
    -- Keys to drop entirely to avoid persisting PII on immutable storage.
    local pii_keys = {
      address = true,
      Address = true,
      line1 = true,
      line2 = true,
      city = true,
      postal = true,
      region = true,
      phone = true,
      email = true,
      subject = true,
      ["Subject"] = true,
      customerId = true,
      ["Customer-Id"] = true,
      customerRef = true,
      ["Customer-Ref"] = true,
      token = true,
      tokenHash = true,
      ["Token-Hash"] = true,
      sessionHash = true,
      ["Session-Hash"] = true,
      jwt = true,
      JWT = true,
      taxId = true,
      vatId = true,
      tracking = true,
      trackingNumber = true,
    }
    
    local function scrub(value)
      local t = type(value)
      if t ~= "table" then
        return value
      end
      local out = {}
      for k, v in pairs(value) do
        if not pii_keys[k] then
          out[k] = scrub(v)
        end
      end
      return out
    end
    
    function Export.write(ev)
      if not path or not json_ok or not ev then
        return
      end
      local f = io.open(path, "a")
      if not f then
        return
      end
      local ok, encoded = pcall(cjson.encode, scrub(ev))
      if ok and encoded then
        f:write(encoded)
        f:write "\n"
      end
      f:close()
    end
    
    -- expose for tests
    Export._scrub = scrub
    
    return Export
    ]====], "ao.shared.export")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.i18n"] = function()
      local loaded, err = load([====[-- Locale helpers: detect locale from path prefixes and normalize to supported locales.
    
    local I18n = {}
    
    local function normalize_locale(locale)
      if not locale or locale == "" then
        return nil
      end
      return locale:lower()
    end
    
    ---Detect locale prefix in a URL path and strip it.
    -- @param path string (e.g. "/en/products/1")
    -- @param supported table array of locales; if nil, no detection performed
    -- @param default_locale string fallback locale
    -- @return locale (string), stripped_path (string)
    function I18n.detect_locale(path, supported, default_locale)
      local locale = normalize_locale(default_locale) or "en"
      local normalized_path = path or "/"
      if not supported or #supported == 0 or not path or path == "" then
        return locale, normalized_path
      end
    
      for _, candidate in ipairs(supported) do
        local lc = normalize_locale(candidate)
        local prefix = "/" .. lc
        if normalized_path == prefix then
          return lc, "/"
        end
        if normalized_path:sub(1, #prefix + 1) == prefix .. "/" then
          return lc, normalized_path:sub(#prefix + 1)
        end
      end
    
      return locale, normalized_path
    end
    
    return I18n
    ]====], "ao.shared.i18n")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.idempotency"] = function()
      local loaded, err = load([====[-- Simple in-memory idempotency registry (lookup/record) shared across AO procs.
    
    local Idem = {}
    local store = {}
    local ttl = tonumber(os.getenv "IDEM_TTL_SECONDS" or "300")
    local max_entries = tonumber(os.getenv "IDEM_MAX_ENTRIES" or "1024")
    
    local function now()
      return os.time()
    end
    
    local function prune()
      local count = 0
      for k, v in pairs(store) do
        if v.expire_at and v.expire_at < now() then
          store[k] = nil
        else
          count = count + 1
        end
      end
      if count > max_entries then
        local oldest_k, oldest_ts
        for k, v in pairs(store) do
          if not oldest_ts or v.recorded_at < oldest_ts then
            oldest_ts, oldest_k = v.recorded_at, k
          end
        end
        if oldest_k then
          store[oldest_k] = nil
        end
      end
    end
    
    function Idem.lookup(request_id)
      prune()
      local v = store[request_id]
      if not v then
        return nil
      end
      return v.resp
    end
    
    -- Legacy-friendly helper used by processes; returns cached response or nil.
    -- Kept separate from lookup to preserve call-sites that expect `check(...)`.
    function Idem.check(request_id)
      return Idem.lookup(request_id)
    end
    
    function Idem.record(request_id, resp)
      prune()
      store[request_id] = {
        resp = resp,
        recorded_at = now(),
        expire_at = now() + ttl,
      }
    end
    
    return Idem
    ]====], "ao.shared.idempotency")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.ids"] = function()
      local loaded, err = load([====[-- Deterministic ID generation and namespacing helpers.
    -- These keep key shapes consistent across processes.
    
    local IDs = {}
    
    local function normalize_path(path)
      if not path or path == "" then
        return "/"
      end
      if path:sub(1, 1) ~= "/" then
        path = "/" .. path
      end
      -- collapse duplicate slashes (lightweight)
      path = path:gsub("//+", "/")
      return path
    end
    
    function IDs.site_key(site_id)
      return ("site:%s"):format(site_id)
    end
    
    function IDs.domain_key(host)
      return ("domain:%s"):format(host)
    end
    
    function IDs.version_key(site_id, version_id)
      return ("version:%s:%s"):format(site_id, version_id)
    end
    
    function IDs.route_key(site_id, path, locale)
      local normalized = normalize_path(path)
      if locale and locale ~= "" then
        return ("route:%s:%s:%s"):format(site_id, normalized, locale:lower())
      end
      return ("route:%s:%s"):format(site_id, normalized)
    end
    
    function IDs.page_key(site_id, page_id, version_id, locale)
      if locale and locale ~= "" then
        return ("page:%s:%s:%s:%s"):format(site_id, page_id, version_id or "active", locale:lower())
      end
      return ("page:%s:%s:%s"):format(site_id, page_id, version_id or "active")
    end
    
    function IDs.layout_key(layout_id, version_id, locale)
      if locale and locale ~= "" then
        return ("layout:%s:%s:%s"):format(layout_id, version_id or "active", locale:lower())
      end
      return ("layout:%s:%s"):format(layout_id, version_id or "active")
    end
    
    function IDs.menu_key(site_id, menu_id, version_id, locale)
      if locale and locale ~= "" then
        return ("menu:%s:%s:%s:%s"):format(site_id, menu_id, version_id or "active", locale:lower())
      end
      return ("menu:%s:%s:%s"):format(site_id, menu_id, version_id or "active")
    end
    
    function IDs.product_key(site_id, sku)
      return ("product:%s:%s"):format(site_id, sku)
    end
    
    function IDs.category_key(site_id, category_id)
      return ("category:%s:%s"):format(site_id, category_id)
    end
    
    function IDs.entitlement_key(subject, asset)
      return ("entitlement:%s:%s"):format(subject, asset)
    end
    
    return IDs
    ]====], "ao.shared.ids")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.jwt"] = function()
      local loaded, err = load([====[-- Minimal JWT HS256 verifier (no clock skew handling).
    local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
    local ok_mime, mime = pcall(require, "mime")
    local ok_json, cjson = pcall(require, "cjson.safe")
    
    local Jwt = {}
    
    local function b64url_decode(input)
      input = input:gsub("-", "+"):gsub("_", "/")
      local pad = #input % 4
      if pad > 0 then
        input = input .. string.rep("=", 4 - pad)
      end
      if ok_mime and mime.unb64 then
        return mime.unb64(input)
      end
      return nil
    end
    
    function Jwt.verify_hs256(token, secret)
      if not token or token == "" or not secret then
        return false, "missing_token"
      end
      if not crypto_ok or not crypto.hmac_sha256_hex then
        return false, "crypto_missing"
      end
      local header_b64, payload_b64, sig_b64 = token:match "([^%.]+)%.([^%.]+)%.([^%.]+)"
      if not (header_b64 and payload_b64 and sig_b64) then
        return false, "invalid_format"
      end
      local signed = header_b64 .. "." .. payload_b64
      local signature = b64url_decode(sig_b64)
      if not signature then
        return false, "bad_signature_b64"
      end
      local expected_hex = crypto.hmac_sha256_hex(signed, secret)
      local expected = expected_hex
        and expected_hex:gsub("%x%x", function(x)
          return string.char(tonumber(x, 16))
        end)
      if not expected or expected ~= signature then
        return false, "signature_mismatch"
      end
      if not ok_json then
        return false, "json_missing"
      end
      local ok_h = pcall(cjson.decode, b64url_decode(header_b64) or "")
      local ok_p, payload = pcall(cjson.decode, b64url_decode(payload_b64) or "")
      if not (ok_h and ok_p) then
        return false, "decode_failed"
      end
      return true, payload
    end
    
    return Jwt
    ]====], "ao.shared.jwt")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.layout_components"] = function()
      local loaded, err = load([====[-- Layout component validator for block-based layouts.
    
    local Layout = {}
    
    local function warn(list, msg)
      table.insert(list, msg)
    end
    
    local validators = {}
    
    validators.hero = function(comp, warnings)
      if not comp.title or comp.title == "" then
        warn(warnings, "hero.title required")
      end
      if comp.image and (not comp.image.alt or comp.image.alt == "") then
        warn(warnings, "hero.image.alt required when image set")
      end
      if comp.image then
        comp.image.loading = comp.image.loading or "lazy"
        comp.image.placeholder = comp.image.placeholder or "blur"
      end
      if comp.cta and not comp.cta.aria_label then
        warn(warnings, "hero.cta.aria_label recommended")
      end
    end
    
    validators.grid = function(comp, warnings)
      if not comp.items or type(comp.items) ~= "table" or #comp.items == 0 then
        warn(warnings, "grid.items must be non-empty array")
      end
    end
    
    validators.carousel = function(comp, warnings)
      if not comp.slides or type(comp.slides) ~= "table" or #comp.slides == 0 then
        warn(warnings, "carousel.slides must be non-empty array")
        return
      end
      for _, slide in ipairs(comp.slides) do
        if not slide.image then
          warn(warnings, "carousel.slide.image required")
        elseif not slide.alt or slide.alt == "" then
          warn(warnings, "carousel.slide.alt required")
        end
        slide.loading = slide.loading or "lazy"
        slide.placeholder = slide.placeholder or "blur"
        if slide.cta and not slide.cta.aria_label then
          warn(warnings, "carousel.slide.cta.aria_label recommended")
        end
      end
    end
    
    validators.rich_text = function(comp, warnings)
      if not comp.body or comp.body == "" then
        warn(warnings, "rich_text.body required")
      end
    end
    
    validators.form = function(comp, warnings)
      if not comp.fields or type(comp.fields) ~= "table" or #comp.fields == 0 then
        warn(warnings, "form.fields must be non-empty array")
        return
      end
      for _, f in ipairs(comp.fields) do
        if not f.name or not f.label then
          warn(warnings, "form.field name and label required")
        end
        if f.type == "button" and not f.aria_label then
          warn(warnings, "form.button aria_label recommended")
        end
      end
    end
    
    local allowed_types = {
      hero = true,
      grid = true,
      carousel = true,
      rich_text = true,
      form = true,
    }
    
    ---Validate array of components.
    -- @return ok:boolean, warnings:table
    function Layout.validate(components)
      local warnings = {}
      if not components or type(components) ~= "table" then
        return true, warnings
      end
      for _, comp in ipairs(components) do
        local typ = comp.type or comp.kind
        if not typ or not allowed_types[typ] then
          warn(warnings, "Unsupported component type")
        else
          local v = validators[typ]
          if v then
            v(comp, warnings)
          end
        end
      end
      return #warnings == 0, warnings
    end
    
    return Layout
    ]====], "ao.shared.layout_components")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.metrics"] = function()
      local loaded, err = load([====[-- Minimal metrics stub: counts and durations written to NDJSON file (mock-friendly).
    
    local Metrics = {}
    
    local LOG_PATH = os.getenv "METRICS_LOG" or "metrics/metrics.log"
    local ENABLED = os.getenv "METRICS_ENABLED" ~= "0"
    local PROM_PATH = os.getenv "METRICS_PROM_PATH"
    local PROM_MODE = os.getenv "METRICS_PROM_MODE"
    local FLUSH_EVERY = tonumber(os.getenv "METRICS_FLUSH_EVERY" or "0")
    local FLUSH_INTERVAL = tonumber(os.getenv "METRICS_FLUSH_INTERVAL_SEC" or "0")
    local counters = {}
    local gauges = {}
    local meta = {}
    local since_flush = 0
    local last_flush = os.time()
    local timer = require "ao.shared.timer"
    local lfs_ok, lfs = pcall(require, "lfs")
    local started = false
    
    local function register(name, kind, help)
      if not name then
        return
      end
      meta[name] = meta[name] or {}
      meta[name].type = kind or meta[name].type or "counter"
      if help then
        meta[name].help = help
      end
    end
    
    Metrics.register = register
    
    local function ensure_dir(path)
      local dir = path:match "(.+)/[^/]+$"
      if dir then
        os.execute(string.format('mkdir -p "%s"', dir))
      end
    end
    
    local function log(event)
      if not ENABLED or not LOG_PATH then
        return
      end
      ensure_dir(LOG_PATH)
      local f = io.open(LOG_PATH, "a")
      if not f then
        return
      end
      f:write(
        string.format(
          '{"ts":"%s","event":"%s","value":%s}\n',
          os.date "!%Y-%m-%dT%H:%M:%SZ",
          event.name or "metric",
          event.value or 0
        )
      )
      f:close()
    end
    
    local function enforce_prom_mode(path)
      if not PROM_MODE or PROM_MODE == "" then
        return
      end
      os.execute(string.format('chmod %s "%s"', PROM_MODE, path))
    end
    
    function Metrics.inc(name, value)
      if os.getenv "METRICS_DISABLED" == "1" then
        return
      end
      value = value or 1
      register(name, "counter")
      counters[name] = (counters[name] or 0) + value
      log { name = name, value = counters[name] }
      since_flush = since_flush + 1
      if FLUSH_EVERY > 0 and since_flush >= FLUSH_EVERY then
        Metrics.flush_prom()
        since_flush = 0
      elseif FLUSH_EVERY == 0 then
        Metrics.flush_prom()
      end
    end
    
    function Metrics.tick()
      if os.getenv "METRICS_DISABLED" == "1" then
        return
      end
      local now = os.time()
      if FLUSH_INTERVAL > 0 and (now - last_flush) >= FLUSH_INTERVAL then
        Metrics.flush_prom()
        last_flush = now
        since_flush = 0
      end
      if FLUSH_INTERVAL > 0 then
        timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
      end
    end
    
    function Metrics.flush_prom()
      if not PROM_PATH then
        return
      end
      -- optional gauges sourced from queue files so gateway can scrape them
      local function file_lines(path)
        if not path or path == "" then
          return nil
        end
        local f = io.open(path, "r")
        if not f then
          return nil
        end
        local n = 0
        for _ in f:lines() do
          n = n + 1
        end
        f:close()
        return n
      end
      local queue_path = os.getenv "AO_QUEUE_PATH"
      local retry_path = os.getenv "AO_WEBHOOK_RETRY_PATH" or os.getenv "AO_RETRY_QUEUE_PATH"
      local breaker_flag = os.getenv "AO_PSP_BREAKER_FLAG"
      local outbox_size = file_lines(queue_path)
      local retry_size = file_lines(retry_path)
      local function file_mtime(path)
        if not lfs_ok or not path or path == "" then
          return nil
        end
        local st = lfs.attributes(path)
        return st and st.modification or nil
      end
      if outbox_size then
        register("ao_outbox_queue_size", "gauge", "Lines present in AO outbox queue file")
        gauges.ao_outbox_queue_size = outbox_size
      end
      local mtime = file_mtime(queue_path)
      if mtime then
        register("ao_outbox_lag_seconds", "gauge", "Seconds since outbox queue file was updated")
        gauges.ao_outbox_lag_seconds = math.max(0, os.time() - mtime)
      end
      if retry_size then
        register("ao_webhook_retry_queue_size", "gauge", "Pending webhook retry queue length")
        gauges.ao_webhook_retry_queue_size = retry_size
      end
      if breaker_flag then
        local bf = io.open(breaker_flag, "r")
        if bf then
          local val = bf:read "*l"
          bf:close()
          register("ao_psp_breaker_open", "gauge", "Payment provider breaker flag (1=open)")
          gauges.ao_psp_breaker_open = tonumber(val) or 0
        end
      end
      local function prom_sanitize(name)
        return (name or "metric"):gsub("[^%w_]", "_")
      end
      local function prom_name(name, kind)
        local base = prom_sanitize(name)
        if kind == "counter" and not base:match "_total$" then
          return base .. "_total"
        end
        return base
      end
      local emitted = {}
      ensure_dir(PROM_PATH)
      local f = io.open(PROM_PATH, "w")
      if not f then
        return
      end
      local function emit(name, kind, value)
        local cfg = meta[name] or { type = kind }
        local pname = prom_name(name, cfg.type or kind)
        if not emitted[pname] then
          if cfg.help then
            f:write(string.format("# HELP %s %s\n", pname, cfg.help))
          end
          f:write(string.format("# TYPE %s %s\n", pname, cfg.type or kind))
          emitted[pname] = true
        end
        f:write(string.format("%s %s\n", pname, tostring(value)))
      end
      for k, v in pairs(counters) do
        emit(k, "counter", v)
      end
      for k, v in pairs(gauges) do
        emit(k, "gauge", v)
      end
      f:close()
      enforce_prom_mode(PROM_PATH)
    end
    
    function Metrics.last_flush_ts()
      return last_flush
    end
    
    function Metrics.get(name)
      return counters[name] or 0
    end
    
    function Metrics.counter(name, value)
      Metrics.inc(name, value)
    end
    
    function Metrics.gauge(name, value)
      if os.getenv "METRICS_DISABLED" == "1" then
        return
      end
      register(name, "gauge")
      gauges[name] = value
      log { name = name, value = value }
    end
    
    function Metrics._reset()
      counters = {}
      gauges = {}
    end
    
    function Metrics.get_gauge(name)
      return gauges[name]
    end
    
    function Metrics.start_background()
      if started then
        return
      end
      started = true
      if FLUSH_INTERVAL > 0 then
        timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
      end
    end
    
    -- Register common AO metrics used by ops/alerts so they get HELP/TYPE lines.
    local default_meta = {
      ao_ingest_apply_ok = { type = "counter", help = "AO ingest events applied successfully" },
      ao_ingest_apply_failed = { type = "counter", help = "AO ingest apply failures" },
      ao_cache_hit = { type = "counter", help = "Cache hits served from AO cache" },
      ao_cache_miss = { type = "counter", help = "Cache misses (recompute)" },
      ao_cache_stale_hit = { type = "counter", help = "Stale cache entries served" },
      ao_cache_stale_fallback = {
        type = "counter",
        help = "Served stale cache because fresh computation failed",
      },
      ao_sitemap_export_total = { type = "counter", help = "Sitemap exports executed" },
      ao_sitemap_export_duration_seconds = {
        type = "gauge",
        help = "Duration of last sitemap export in seconds",
      },
      ao_feed_export_total = { type = "counter", help = "Catalog feed exports executed" },
      ao_feed_export_failed = { type = "counter", help = "Catalog feed export failures" },
      ao_feed_export_duration_seconds = {
        type = "gauge",
        help = "Duration of last catalog feed export in seconds",
      },
      ao_page_view_total = { type = "counter", help = "Page view events emitted" },
      ao_product_view_total = { type = "counter", help = "Product view events emitted" },
      ao_risk_event_total = { type = "counter", help = "Risk signals emitted" },
      ao_subscription_start_total = { type = "counter", help = "Subscriptions started" },
      ao_subscription_cancel_total = { type = "counter", help = "Subscriptions cancelled" },
      ao_subscription_churn_total = { type = "counter", help = "Subscription churn events" },
      ao_outbox_queue_size = {
        type = "gauge",
        help = "Lines present in AO outbox queue file (write side export)",
      },
      ao_outbox_lag_seconds = {
        type = "gauge",
        help = "Seconds since outbox queue file was last updated",
      },
      ao_webhook_retry_queue_size = {
        type = "gauge",
        help = "Webhook retry queue size from write bridge",
      },
      ao_psp_breaker_open = { type = "gauge", help = "Breaker flag value (1=open) for PSP webhooks" },
    }
    
    for name, cfg in pairs(default_meta) do
      register(name, cfg.type, cfg.help)
    end
    
    -- auto-start if interval specified
    Metrics.start_background()
    
    return Metrics
    ]====], "ao.shared.metrics")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.persist"] = function()
      local loaded, err = load([====[-- Persistence adapter with three tiers:
    -- 1) WeaveDB export (append-only, PII-scrubbed) if AO_WEAVEDB_EXPORT_PATH is set.
    -- 2) Local snapshot (PII-scrubbed) when AO_STATE_DIR is set.
    -- 3) In-memory fallback.
    
    local persist = {}
    
    local base = os.getenv "AO_STATE_DIR"
    local export_ok, export = pcall(require, "ao.shared.export")
    local json_ok, cjson = pcall(require, "cjson.safe")
    
    -- PII keys to remove before writing immutable storage.
    local pii_keys = {
      address = true,
      Address = true,
      line1 = true,
      line2 = true,
      city = true,
      postal = true,
      region = true,
      phone = true,
      email = true,
      subject = true,
      ["Subject"] = true,
      customerId = true,
      ["Customer-Id"] = true,
      customerRef = true,
      ["Customer-Ref"] = true,
      token = true,
      tokenHash = true,
      ["Token-Hash"] = true,
      sessionHash = true,
      ["Session-Hash"] = true,
      jwt = true,
      JWT = true,
    }
    
    local function scrub(value)
      local t = type(value)
      if t ~= "table" then
        return value
      end
      local out = {}
      for k, v in pairs(value) do
        if not pii_keys[k] then
          out[k] = scrub(v)
        end
      end
      return out
    end
    
    local function path_for(ns)
      if not base then
        return nil
      end
      return base .. "/" .. ns .. ".json"
    end
    
    function persist.load(ns, default_value)
      local p = path_for(ns)
      if not p or not json_ok then
        return default_value
      end
      local f = io.open(p, "r")
      if not f then
        return default_value
      end
      local content = f:read "*a"
      f:close()
      local decoded = cjson.decode(content or "")
      if type(decoded) == "table" then
        return decoded
      end
      return default_value
    end
    
    function persist.save(ns, value)
      local p = path_for(ns)
      -- Append PII-scrubbed state snapshot to WeaveDB export (immutable)
      if export_ok and type(export.write) == "function" then
        export.write {
          kind = "state_snapshot",
          ns = ns,
          ts = os.time(),
          state = scrub(value),
        }
      end
      -- Write local snapshot (mutable, used for fast reload)
      if p and json_ok then
        local ok, encoded = pcall(cjson.encode, scrub(value))
        if not ok or not encoded then
          return
        end
        local f = io.open(p, "w")
        if not f then
          return
        end
        f:write(encoded)
        f:close()
      end
    end
    
    return persist
    ]====], "ao.shared.persist")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.schema"] = function()
      local loaded, err = load([====[-- Minimal JSON Schema validator with optional python/jsonschema backend.
    -- If SCHEMA_VALIDATOR=python and python3+jsonschema are available,
    -- uses that; otherwise falls back to the embedded validator below.
    
    local Schema = {}
    local SCHEMA_MODE = os.getenv "SCHEMA_VALIDATOR" or "auto" -- auto|python|embedded
    
    -- Schemas embedded as Lua tables (converted from schemas/*.json)
    local SCHEMAS = {
      page = {
        type = "object",
        required = { "id", "title", "blocks" },
        properties = {
          id = { type = "string" },
          title = { type = "string" },
          locale = { type = "string" },
          layoutId = { type = "string" },
          blocks = { type = "array", items = { type = "object" } },
        },
      },
      product = {
        type = "object",
        required = { "sku", "name" },
        properties = {
          sku = { type = "string" },
          name = { type = "string" },
          description = { type = "string" },
          price = { type = "number" },
          assets = { type = "array", items = { type = "string" } },
        },
      },
      route = {
        type = "object",
        required = { "siteId", "path", "pageId" },
        properties = {
          siteId = { type = "string" },
          path = { type = "string" },
          locale = { type = "string" },
          pageId = { type = "string" },
          type = { type = "string" },
        },
      },
      publish = {
        type = "object",
        required = { "publishId", "versionId", "manifestTx" },
        properties = {
          publishId = { type = "string" },
          versionId = { type = "string" },
          manifestTx = { type = "string" },
          activatedAt = { type = "string" },
          rollbackTo = { type = "string" },
        },
      },
      entitlement = {
        type = "object",
        required = { "subject", "asset" },
        properties = {
          subject = { type = "string", minLength = 1, maxLength = 128 },
          asset = { type = "string", minLength = 1, maxLength = 256 },
          policy = { type = "string", minLength = 1, maxLength = 128 },
        },
      },
      accessAsset = {
        type = "object",
        required = { "asset", "ref" },
        properties = {
          asset = { type = "string", minLength = 1, maxLength = 256, pattern = "^[%w%-%._:/]+$" },
          ref = { type = "string", minLength = 1, maxLength = 2048, pattern = "^ar://[%w%-]+$" },
          visibility = { type = "string", enum = { "protected", "public", "private" } },
        },
      },
      registryConfig = {
        type = "object",
        required = {},
        properties = {
          version = { type = "string", minLength = 1, maxLength = 128 },
          metadata = { type = "object" },
          flags = {
            type = "object",
            properties = {
              cors = { type = "boolean" },
              corsAllowlist = {
                type = "array",
                minItems = 1,
                items = { type = "string", pattern = "^https?://[%w%.-]+(:%d+)?/?$" },
              },
              immutable = { type = "boolean" },
              allowUploads = { type = "boolean" },
              ttlSeconds = { type = "number", minimum = 0, maximum = 31536000 },
              rateLimitPerMinute = { type = "number", minimum = 0, maximum = 10000 },
              maxUploadBytes = { type = "number", minimum = 0, maximum = 104857600 },
              allowAnonRead = { type = "boolean" },
              requireMfa = { type = "boolean" },
            },
          },
          region = { type = "string", enum = { "eu", "us", "apac" } },
          tier = { type = "string", enum = { "dev", "staging", "prod" } },
          codeHash = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
          buildId = { type = "string", minLength = 1, maxLength = 128 },
          signerPubKey = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
          tableProfile = {
            type = "string",
            enum = {
              "minimal",
              "core-observability",
              "auth-rbac",
              "commerce-lite",
              "monitoring-outbox",
            },
          },
          schemaManifestTx = { type = "string", pattern = "^[A-Za-z0-9_-]{10,128}$" },
          schemaHash = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
          policies = {
            type = "object",
            properties = {
              allowAnonymousRead = { type = "boolean" },
              allowAnonymousWrite = { type = "boolean" },
              auditLevel = { type = "string", enum = { "none", "basic", "full" } },
              dataResidency = { type = "string", enum = { "eu", "us", "apac", "global" } },
              piiHandling = { type = "string", enum = { "deny", "mask", "allow" } },
              allowedOrigins = {
                type = "array",
                items = { type = "string", pattern = "^https?://[%w%.-]+(:%d+)?/?$" },
                minItems = 1,
              },
              ipAllowlist = {
                type = "array",
                items = { type = "string", pattern = "^%d+%.%d+%.%d+%.%d+/%d%d?$" },
                minItems = 0,
              },
              allowedMethods = {
                type = "array",
                items = {
                  type = "string",
                  enum = { "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" },
                },
                minItems = 1,
              },
            },
          },
        },
      },
      arweaveResponse = {
        type = "object",
        required = { "status" },
        properties = {
          status = { type = "string" },
          message = { type = "string" },
          tx = { type = "string" },
        },
      },
    }
    
    local function type_of(value)
      local t = type(value)
      if t == "table" then
        local i = 0
        for _ in pairs(value) do
          i = i + 1
          if value[i] == nil then
            return "object"
          end
        end
        return "array"
      end
      return t
    end
    
    local function validate_properties(value, schema, path, errors)
      if schema.required then
        for _, req in ipairs(schema.required) do
          if value[req] == nil then
            table.insert(errors, path .. req .. " is required")
          end
        end
      end
      if schema.properties then
        for name, prop in pairs(schema.properties) do
          if value[name] ~= nil then
            local actual_type = type_of(value[name])
            if prop.type and actual_type ~= prop.type then
              table.insert(errors, path .. name .. " expected " .. prop.type .. ", got " .. actual_type)
            end
            if prop.enum then
              local ok_enum = false
              for _, ev in ipairs(prop.enum) do
                if ev == value[name] then
                  ok_enum = true
                end
              end
              if not ok_enum then
                table.insert(errors, path .. name .. " not in enum")
              end
            end
            if prop.pattern and actual_type == "string" then
              if not tostring(value[name]):match(prop.pattern) then
                table.insert(errors, path .. name .. " does not match pattern")
              end
            end
            if
              prop.minLength
              and actual_type == "string"
              and #tostring(value[name]) < prop.minLength
            then
              table.insert(errors, path .. name .. " shorter than minLength")
            end
            if
              prop.maxLength
              and actual_type == "string"
              and #tostring(value[name]) > prop.maxLength
            then
              table.insert(errors, path .. name .. " longer than maxLength")
            end
            if prop.type == "array" and prop.items and value[name] ~= nil then
              for idx, item in ipairs(value[name]) do
                local item_type = type_of(item)
                if prop.items.type and item_type ~= prop.items.type then
                  table.insert(
                    errors,
                    path
                      .. name
                      .. "["
                      .. idx
                      .. "] expected "
                      .. prop.items.type
                      .. ", got "
                      .. item_type
                  )
                end
                if
                  prop.items.pattern
                  and type(item) == "string"
                  and not tostring(item):match(prop.items.pattern)
                then
                  table.insert(errors, path .. name .. "[" .. idx .. "] does not match pattern")
                end
                if prop.items.enum then
                  local ok_enum = false
                  for _, ev in ipairs(prop.items.enum) do
                    if ev == item then
                      ok_enum = true
                    end
                  end
                  if not ok_enum then
                    table.insert(errors, path .. name .. "[" .. idx .. "] not in enum")
                  end
                end
              end
              if prop.minItems and #value[name] < prop.minItems then
                table.insert(errors, path .. name .. " fewer than minItems")
              end
            elseif prop.type == "object" and prop.properties and type(value[name]) == "table" then
              validate_properties(value[name], prop, path .. name .. ".", errors)
            end
            if prop.format == "date-time" and actual_type == "string" then
              if not tostring(value[name]):match "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$" then
                table.insert(errors, path .. name .. " invalid date-time")
              end
            end
            if prop.minimum and actual_type == "number" and value[name] < prop.minimum then
              table.insert(errors, path .. name .. " below minimum")
            end
            if prop.maximum and actual_type == "number" and value[name] > prop.maximum then
              table.insert(errors, path .. name .. " above maximum")
            end
          end
        end
      end
    end
    
    local function validate_against(schema, value, path, errors)
      local actual = type_of(value)
      if schema.type and actual ~= schema.type then
        table.insert(errors, path .. "expected " .. schema.type .. ", got " .. actual)
        return
      end
      if schema.type == "object" and type(value) == "table" then
        validate_properties(value, schema, path, errors)
      elseif schema.type == "array" and type(value) == "table" then
        if schema.items then
          for idx, item in ipairs(value) do
            validate_against(schema.items, item, path .. "[" .. idx .. "].", errors)
          end
        end
      end
    end
    
    function Schema.validate(schema_name, value)
      if SCHEMA_MODE ~= "embedded" then
        local ok, err = Schema.validate_python(schema_name, value)
        if ok ~= nil then
          return ok, err
        end -- nil means fallback to embedded
      end
      local schema = SCHEMAS[schema_name]
      if not schema then
        return true
      end
      local errors = {}
      validate_against(schema, value, "", errors)
      if #errors > 0 then
        return false, errors
      end
      return true
    end
    
    -- Validate against a schema table passed at runtime (same rules as embedded validator)
    function Schema.validate_custom(schema_table, value)
      if not schema_table then
        return true
      end
      local errors = {}
      validate_against(schema_table, value, "", errors)
      if #errors > 0 then
        return false, errors
      end
      return true
    end
    
    -- Python/jsonschema validator (optional). Returns nil if not usable.
    function Schema.validate_python(schema_name, value)
      local has_py = os.execute 'python3 -c "import jsonschema" >/dev/null 2>&1'
      if has_py ~= true and has_py ~= 0 then
        return nil, "python_jsonschema_missing"
      end
      local schema_path = "schemas/" .. schema_name .. ".schema.json"
      local f = io.open(schema_path, "r")
      if not f then
        return nil, "schema_not_found"
      end
      f:close()
      local tmp = os.tmpname() .. ".json"
      local jf = io.open(tmp, "w")
      if not jf then
        return nil, "tmp_write_failed"
      end
      local function json_encode(v)
        local t = type(v)
        if t == "nil" then
          return "null"
        end
        if t == "boolean" then
          return v and "true" or "false"
        end
        if t == "number" then
          return tostring(v)
        end
        if t == "string" then
          return string.format("%q", v)
        end
        if t == "table" then
          local is_array = true
          local i = 0
          for _, _ in pairs(v) do
            i = i + 1
            if v[i] == nil then
              is_array = false
            end
          end
          local parts = {}
          if is_array then
            for _, item in ipairs(v) do
              table.insert(parts, json_encode(item))
            end
            return "[" .. table.concat(parts, ",") .. "]"
          else
            for k, item in pairs(v) do
              table.insert(parts, string.format("%q:%s", tostring(k), json_encode(item)))
            end
            return "{" .. table.concat(parts, ",") .. "}"
          end
        end
        return '"<unsupported>"'
      end
      jf:write(json_encode(value))
      jf:close()
      local cmd = string.format(
        [[python3 - <<'PY'
    import json,sys,jsonschema
    with open(%q) as f: schema=json.load(f)
    with open(%q) as f: inst=json.load(f)
    try:
     jsonschema.validate(inst, schema)
     sys.exit(0)
    except jsonschema.ValidationError:
     sys.exit(1)
    PY]],
        schema_path,
        tmp
      )
      local ok = os.execute(cmd)
      os.remove(tmp)
      if ok == 0 or ok == true then
        return true
      end
      -- If validation fails, treat as schema error; otherwise fallback
      if ok == 256 or ok == false then
        return false, { "python_validator_failed" }
      end
      return nil, "python_validator_unavailable"
    end
    
    return Schema
    ]====], "ao.shared.schema")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.seo"] = function()
      local loaded, err = load([====[-- Minimal SEO helpers (JSON-LD generators). Not wired by default.
    
    local cjson_ok, cjson = pcall(require, "cjson.safe")
    
    local SEO = {}
    
    local function encode(ld)
      if not cjson_ok then
        return nil
      end
      return cjson.encode(ld)
    end
    
    -- Products ---------------------------------------------------------------
    function SEO.product_ld(product)
      return encode {
        ["@context"] = "https://schema.org",
        ["@type"] = "Product",
        name = product.name,
        description = product.description,
        sku = product.sku,
        image = product.image,
        brand = product.brand,
        category = product.category,
        offers = {
          ["@type"] = "Offer",
          price = product.price,
          priceCurrency = product.currency,
          availability = product.available and "https://schema.org/InStock"
            or "https://schema.org/OutOfStock",
          url = product.url,
          itemCondition = product.condition,
        },
      }
    end
    
    -- Articles / blog --------------------------------------------------------
    function SEO.article_ld(article)
      return encode {
        ["@context"] = "https://schema.org",
        ["@type"] = "Article",
        headline = article.title,
        datePublished = article.publishedAt,
        dateModified = article.updatedAt or article.publishedAt,
        author = article.author and { ["@type"] = "Person", name = article.author } or nil,
        image = article.image,
        description = article.description,
        mainEntityOfPage = article.url,
      }
    end
    
    -- Breadcrumbs ------------------------------------------------------------
    function SEO.breadcrumb_ld(crumbs)
      local item_list = {}
      for idx, crumb in ipairs(crumbs or {}) do
        table.insert(item_list, {
          ["@type"] = "ListItem",
          position = idx,
          name = crumb.name,
          item = crumb.url,
        })
      end
      return encode {
        ["@context"] = "https://schema.org",
        ["@type"] = "BreadcrumbList",
        itemListElement = item_list,
      }
    end
    
    -- FAQ --------------------------------------------------------------------
    function SEO.faq_ld(items)
      local qas = {}
      for _, qa in ipairs(items or {}) do
        table.insert(qas, {
          ["@type"] = "Question",
          name = qa.question,
          acceptedAnswer = { ["@type"] = "Answer", text = qa.answer },
        })
      end
      return encode {
        ["@context"] = "https://schema.org",
        ["@type"] = "FAQPage",
        mainEntity = qas,
      }
    end
    
    -- Organization -----------------------------------------------------------
    function SEO.organization_ld(org)
      return encode {
        ["@context"] = "https://schema.org",
        ["@type"] = "Organization",
        name = org.name,
        url = org.url,
        logo = org.logo,
        sameAs = org.sameAs,
        contactPoint = org.contact and {
          ["@type"] = "ContactPoint",
          telephone = org.contact.phone,
          contactType = org.contact.type or "customer support",
          areaServed = org.contact.areaServed,
          availableLanguage = org.contact.languages,
        } or nil,
      }
    end
    
    -- WebPage ----------------------------------------------------------------
    function SEO.page_ld(page)
      return encode {
        ["@context"] = "https://schema.org",
        ["@type"] = "WebPage",
        name = page.title or page.name,
        description = page.description,
        url = page.url,
        inLanguage = page.locale,
      }
    end
    
    -- Canonical / hreflang helpers -------------------------------------------
    function SEO.canonical(base_url, path)
      if not base_url or base_url == "" then
        return path
      end
      if base_url:sub(-1) == "/" then
        base_url = base_url:sub(1, -2)
      end
      if path:sub(1, 1) ~= "/" then
        path = "/" .. path
      end
      return base_url .. path
    end
    
    ---Build hreflang link map.
    -- @param base_url string e.g. https://example.com
    -- @param path string normalized path without locale prefix
    -- @param locales { supported = { "en", "de" }, default = "en" }
    function SEO.hreflang_links(base_url, path, locales)
      if not locales or not locales.supported then
        return {}
      end
      local links = {}
      for _, loc in ipairs(locales.supported) do
        local href = SEO.canonical(base_url, "/" .. loc .. path)
        table.insert(links, { rel = "alternate", hreflang = loc:lower(), href = href })
      end
      -- x-default
      local default_href = SEO.canonical(base_url, "/" .. (locales.default or "en") .. path)
      table.insert(links, { rel = "alternate", hreflang = "x-default", href = default_href })
      return links
    end
    
    -- Sitemaps / robots.txt --------------------------------------------------
    function SEO.sitemap(urls)
      local buffer = {
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
      }
      for _, u in ipairs(urls or {}) do
        table.insert(buffer, "<url>")
        table.insert(buffer, string.format("<loc>%s</loc>", u.loc))
        if u.lastmod then
          table.insert(buffer, string.format("<lastmod>%s</lastmod>", u.lastmod))
        end
        if u.changefreq then
          table.insert(buffer, string.format("<changefreq>%s</changefreq>", u.changefreq))
        end
        if u.priority then
          table.insert(buffer, string.format("<priority>%.1f</priority>", u.priority))
        end
        table.insert(buffer, "</url>")
      end
      table.insert(buffer, "</urlset>")
      return table.concat(buffer, "\n")
    end
    
    function SEO.robots_txt(opts)
      opts = opts or {}
      local lines = {
        "User-agent: *",
        string.format("Disallow: %s", opts.disallow or ""),
      }
      if opts.allow then
        table.insert(lines, string.format("Allow: %s", opts.allow))
      end
      if opts.sitemap then
        table.insert(lines, "Sitemap: " .. opts.sitemap)
      end
      return table.concat(lines, "\n")
    end
    
    return SEO
    ]====], "ao.shared.seo")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.timer"] = function()
      local loaded, err = load([====[-- Minimal timer abstraction using luv if available.
    -- Returns no-op functions when luv is absent.
    
    local ok, uv = pcall(require, "luv")
    
    local Timer = {}
    local started = false
    
    function Timer.start(interval_sec, fn)
      if not ok or not uv or started then
        return
      end
      if not interval_sec or interval_sec <= 0 then
        return
      end
      local t = uv.new_timer()
      if not t then
        return
      end
      started = true
      t:start(interval_sec * 1000, interval_sec * 1000, function()
        pcall(fn)
      end)
    end
    
    function Timer.is_started()
      return started
    end
    
    return Timer
    ]====], "ao.shared.timer")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.shared.validation"] = function()
      local loaded, err = load([====[-- Shared schema validation and payload guards (lightweight).
    -- This keeps minimal synchronous guards in-process; deeper JSON schema checks
    -- should be handled by the upstream bridge or a dedicated validator.
    
    local Validation = {}
    
    Validation.required_tags = {
      "Action",
      "Request-Id",
    }
    
    local function contains(list, value)
      for _, v in ipairs(list) do
        if v == value then
          return true
        end
      end
      return false
    end
    
    function Validation.require_tags(msg, extra)
      local missing = {}
      for _, key in ipairs(Validation.required_tags) do
        if msg[key] == nil then
          table.insert(missing, key)
        end
      end
      if extra then
        for _, key in ipairs(extra) do
          if msg[key] == nil then
            table.insert(missing, key)
          end
        end
      end
      if #missing > 0 then
        return false, missing
      end
      return true
    end
    
    function Validation.require_action(msg, allowed)
      local action = msg.Action
      if not action then
        return false, "missing_action"
      end
      if allowed and not contains(allowed, action) then
        return false, "unknown_action"
      end
      return true
    end
    
    -- Convenience check for allowlist
    function Validation.is_allowed_action(action, allowed)
      if not action then
        return false
      end
      if not allowed then
        return true
      end
      return contains(allowed, action)
    end
    
    -- Validate presence of required fields in a table payload.
    function Validation.require_fields(tbl, fields)
      local missing = {}
      for _, f in ipairs(fields) do
        if tbl[f] == nil then
          table.insert(missing, f)
        end
      end
      if #missing > 0 then
        return false, missing
      end
      return true
    end
    
    -- Validate that no unexpected fields are present (shallow).
    function Validation.require_no_extras(tbl, allowed_fields)
      if not allowed_fields then
        return true
      end
      local allowed = {
        -- Cross-cutting auth/telemetry fields that every handler should tolerate.
        Nonce = true,
        nonce = true,
        ts = true,
        timestamp = true,
        ["Timestamp"] = true,
        Signature = true,
        signature = true,
        ["Signature-Ref"] = true,
        Authorization = true,
        authorization = true,
        auth = true,
        JWT = true,
        jwt = true,
      }
      for _, f in ipairs(allowed_fields) do
        allowed[f] = true
      end
      local extras = {}
      for k, _ in pairs(tbl) do
        if not allowed[k] then
          table.insert(extras, k)
        end
      end
      if #extras > 0 then
        return false, extras
      end
      return true
    end
    
    -- Optional payload size guard (bytes when serialized length provided).
    function Validation.check_size(len, max_bytes, field)
      if not max_bytes or max_bytes <= 0 or not len then
        return true
      end
      if len > max_bytes then
        return false, ("too_large:%s"):format(field or "?")
      end
      return true
    end
    
    function Validation.assert_type(value, expected, field)
      if type(value) ~= expected then
        return false, ("invalid_type:%s"):format(field or "?")
      end
      return true
    end
    
    -- Check maximum string length.
    function Validation.check_length(value, max_len, field)
      if not value or not max_len or max_len <= 0 then
        return true
      end
      if #tostring(value) > max_len then
        return false, ("too_long:%s"):format(field or "?")
      end
      return true
    end
    
    local function is_array(tbl)
      local i = 0
      for _ in pairs(tbl) do
        i = i + 1
        if tbl[i] == nil then
          return false
        end
      end
      return true
    end
    
    local function json_encoded_length(value)
      local t = type(value)
      if t == "nil" then
        return 4
      end -- null
      if t == "boolean" then
        return value and 4 or 5
      end -- true/false
      if t == "number" then
        return #tostring(value)
      end
      if t == "string" then
        return #string.format("%q", value)
      end
      if t == "table" then
        if is_array(value) then
          local sum = 2 -- []
          local first = true
          for _, v in ipairs(value) do
            if not first then
              sum = sum + 1
            end -- comma
            sum = sum + json_encoded_length(v)
            first = false
          end
          return sum
        else
          local sum = 2 -- {}
          local first = true
          for k, v in pairs(value) do
            if not first then
              sum = sum + 1
            end -- comma
            sum = sum + #string.format("%q", tostring(k)) + 1 + json_encoded_length(v) -- colon
            first = false
          end
          return sum
        end
      end
      return #tostring(value)
    end
    
    -- Rough estimate of JSON-encoded length (bytes) for payload size guards.
    function Validation.estimate_json_length(value)
      return json_encoded_length(value)
    end
    
    -- Envelope/command validation used by both write and AO processes.
    -- Normalizes common field names so downstream code can rely on canonical keys.
    function Validation.validate_envelope(cmd)
      if not cmd then
        return false, { "missing_envelope" }
      end
      cmd.action = cmd.action or cmd.Action
      cmd.requestId = cmd.requestId or cmd["Request-Id"]
      cmd.payload = cmd.payload or cmd.Payload or {}
      cmd.actor = cmd.actor or cmd.Actor
      cmd.actorRole = cmd.actorRole or cmd["Actor-Role"] or cmd.role
      cmd.tenant = cmd.tenant or cmd.Tenant or cmd["Tenant-Id"]
      cmd.siteId = cmd.siteId or cmd["Site-Id"] or cmd.SiteId
      cmd.gatewayId = cmd.gatewayId or cmd["Gateway-Id"] or cmd.gateway
    
      local ok_tags, missing = Validation.require_tags {
        Action = cmd.action,
        ["Request-Id"] = cmd.requestId,
      }
      if not ok_tags then
        return false, missing
      end
      return true
    end
    
    -- Per-action payload validation stub (can be extended with schemas).
    function Validation.validate_action(_action, _payload)
      return true
    end
    
    -- Optional payload size guard; falls back to estimate when length not provided.
    function Validation.check_payload_size(payload, max_bytes)
      if not max_bytes or max_bytes <= 0 then
        return true
      end
      local est = Validation.estimate_json_length(payload)
      if est > max_bytes then
        return false, ("too_large:%s"):format(max_bytes)
      end
      return true
    end
    
    -- Nonce/timestamp helpers (no-ops by default; override in stricter builds).
    function Validation.require_nonce_fields(_msg)
      return true
    end
    
    function Validation.require_timestamp(_msg)
      return true
    end
    
    return Validation
    ]====], "ao.shared.validation")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.registry.process"] = function()
      local loaded, err = load([====[-- Registry process handlers: domains, sites, versions, roles.
-- Lightweight in-memory scaffolding to keep contracts testable.

local codec = require "ao.shared.codec"
local validation = require "ao.shared.validation"
local auth = require "ao.shared.auth"
local idem = require "ao.shared.idempotency"
local audit = require "ao.shared.audit"
local metrics = require "ao.shared.metrics"
local schema = require "ao.shared.schema"
local json_ok, json = pcall(require, "cjson.safe")
local persist = require "ao.shared.persist"

local handlers = {}
local allowed_actions = {
  "GetSiteByHost",
  "GetSiteConfig",
  "RegisterGateway",
  "UpdateGatewayStatus",
  "ResolveGatewayForHost",
  "ListGateways",
  "RegisterSite",
  "BindDomain",
  "SetActiveVersion",
  "GrantRole",
  "UpdateTrustResolvers",
  "GetTrustedResolvers",
  "PublishTrustedRelease",
  "RevokeTrustedRelease",
  "GetTrustedReleaseByVersion",
  "GetTrustedReleaseByRoot",
  "GetTrustedRoot",
  "SetIntegrityPolicyPause",
  "GetIntegrityPolicy",
  "SetIntegrityAuthority",
  "GetIntegrityAuthority",
  "AppendIntegrityAuditCommitment",
  "GetIntegrityAuditState",
  "GetIntegritySnapshot",
  "FlagResolver",
  "UnflagResolver",
  "GetResolverFlags",
}

local role_policy = {
  RegisterGateway = { "admin", "registry-admin" },
  UpdateGatewayStatus = { "admin", "registry-admin" },
  RegisterSite = { "admin", "registry-admin" },
  BindDomain = { "admin", "registry-admin" },
  SetActiveVersion = { "admin", "registry-admin" },
  GrantRole = { "admin", "registry-admin" },
  UpdateTrustResolvers = { "admin", "registry-admin" },
  GetTrustedResolvers = { "admin", "registry-admin" },
  PublishTrustedRelease = { "admin", "registry-admin" },
  RevokeTrustedRelease = { "admin", "registry-admin" },
  SetIntegrityPolicyPause = { "admin", "registry-admin" },
  SetIntegrityAuthority = { "admin", "registry-admin" },
  AppendIntegrityAuditCommitment = { "admin", "registry-admin" },
  FlagResolver = { "admin", "registry-admin" },
  UnflagResolver = { "admin", "registry-admin" },
  GetResolverFlags = { "admin", "registry-admin" },
}

local hmac_skip_actions = {
  GetSiteByHost = true,
  GetSiteConfig = true,
  ResolveGatewayForHost = true,
  ListGateways = true,
  GetTrustedResolvers = true,
  GetTrustedReleaseByVersion = true,
  GetTrustedReleaseByRoot = true,
  GetTrustedRoot = true,
  GetIntegrityPolicy = true,
  GetIntegrityAuthority = true,
  GetIntegrityAuditState = true,
  GetIntegritySnapshot = true,
  GetResolverFlags = true,
}

-- pseudo-state kept in-memory for now; AO runtime would persist this.
local state = persist.load("registry_state", {
  sites = {}, -- siteId => {config = {}, createdAt = ts}
  domains = {}, -- host => siteId
  gateways = {}, -- gatewayId => { id, url, region, country, capacityWeight, score, status, lastSeen, domains = {} }
  active_versions = {}, -- siteId => versionId
  roles = {}, -- siteId => map[user] = role
  trust = { resolvers = {}, manifestTx = nil, updatedAt = nil },
  integrity = {
    releases = {}, -- "<component>@<version>" => release object
    roots = {}, -- root => "<component>@<version>"
    active = {}, -- component => version
    policy = {
      activeRoot = nil,
      activePolicyHash = "policy-unset",
      paused = false,
      maxCheckInAgeSec = 3600,
      updatedAt = nil,
      pausedAt = nil,
      pausedBy = nil,
      pauseReason = nil,
    },
    authority = {
      root = "authority-root-unset",
      upgrade = "authority-upgrade-unset",
      emergency = "authority-emergency-unset",
      reporter = "authority-reporter-unset",
      signatureRefs = { "authority-root-unset" },
      updatedAt = nil,
    },
    audit = {
      seqFrom = 0,
      seqTo = 0,
      merkleRoot = "audit-root-unset",
      metaHash = "audit-meta-unset",
      reporterRef = "authority-reporter-unset",
      acceptedAt = "1970-01-01T00:00:00Z",
    },
  },
  resolver_flags = {}, -- resolverId => { flag = "suspicious"|"blocked"|"ok", reason, raisedAt, raisedBy }
})

local MAX_CONFIG_BYTES = tonumber(os.getenv "REGISTRY_MAX_CONFIG_BYTES" or "") or (16 * 1024)
local FLAGS_PATH = os.getenv "AO_FLAGS_PATH"
local WAL_PATH = os.getenv "AO_WAL_PATH"

local function now_iso()
  -- coarse timestamp for audit/debug; determinism is sufficient here.
  return os.date "!%Y-%m-%dT%H:%M:%SZ"
end

local function ensure_integrity_state()
  state.integrity = state.integrity or {}
  state.integrity.releases = state.integrity.releases or {}
  state.integrity.roots = state.integrity.roots or {}
  state.integrity.active = state.integrity.active or {}

  state.integrity.policy = state.integrity.policy or {}
  local policy = state.integrity.policy
  if policy.activePolicyHash == nil or policy.activePolicyHash == "" then
    policy.activePolicyHash = "policy-unset"
  end
  if policy.maxCheckInAgeSec == nil then
    policy.maxCheckInAgeSec = 3600
  end
  if policy.paused == nil then
    policy.paused = false
  end

  state.integrity.authority = state.integrity.authority or {}
  local authority = state.integrity.authority
  authority.root = authority.root or "authority-root-unset"
  authority.upgrade = authority.upgrade or "authority-upgrade-unset"
  authority.emergency = authority.emergency or "authority-emergency-unset"
  authority.reporter = authority.reporter or "authority-reporter-unset"
  if type(authority.signatureRefs) ~= "table" or #authority.signatureRefs == 0 then
    authority.signatureRefs = { authority.root }
  end

  state.integrity.audit = state.integrity.audit or {}
  local audit_state = state.integrity.audit
  if type(audit_state.seqFrom) ~= "number" then
    audit_state.seqFrom = 0
  end
  if type(audit_state.seqTo) ~= "number" then
    audit_state.seqTo = 0
  end
  audit_state.merkleRoot = audit_state.merkleRoot or "audit-root-unset"
  audit_state.metaHash = audit_state.metaHash or "audit-meta-unset"
  audit_state.reporterRef = audit_state.reporterRef or authority.reporter
  audit_state.acceptedAt = audit_state.acceptedAt or "1970-01-01T00:00:00Z"
end

ensure_integrity_state()

local function ensure_gateway_state()
  state.gateways = state.gateways or {}
  for gateway_id, gateway in pairs(state.gateways) do
    if type(gateway) ~= "table" then
      state.gateways[gateway_id] = nil
    else
      gateway.id = gateway.id or gateway_id
      gateway.url = gateway.url or ""
      gateway.region = gateway.region or ""
      gateway.country = gateway.country or ""
      gateway.capacityWeight = tonumber(gateway.capacityWeight) or 0
      gateway.score = tonumber(gateway.score) or 0
      gateway.status = gateway.status or "offline"
      gateway.lastSeen = gateway.lastSeen or "1970-01-01T00:00:00Z"
      if type(gateway.domains) ~= "table" then
        gateway.domains = {}
      end
    end
  end
end

ensure_gateway_state()

local function append_log(path, obj)
  if not path or path == "" or not json_ok then
    return
  end
  local line = json.encode(obj)
  if not line then
    return
  end
  local f = io.open(path, "a")
  if f then
    f:write(line)
    f:write "\n"
    f:close()
  end
end

local function persist_flag_event(ev)
  append_log(WAL_PATH, ev)
  append_log(FLAGS_PATH, ev)
end

function handlers.GetSiteByHost(msg)
  local ok, missing = validation.require_fields(msg, { "Host" })
  if not ok then
    return codec.error("INVALID_INPUT", "Host is required", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Host",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_len, err = validation.check_length(msg.Host, 255, "Host")
  if not ok_len then
    return codec.error("INVALID_INPUT", err, { field = "Host" })
  end
  local site_id = state.domains[msg.Host]
  if not site_id then
    return codec.error("NOT_FOUND", "Domain not bound", { host = msg.Host })
  end
  return codec.ok {
    siteId = site_id,
    activeVersion = state.active_versions[site_id],
  }
end

function handlers.GetSiteConfig(msg)
  local ok, missing = validation.require_fields(msg, { "Site-Id" })
  if not ok then
    return codec.error("INVALID_INPUT", "Site-Id is required", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Site-Id",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_len, err = validation.check_length(msg["Site-Id"], 128, "Site-Id")
  if not ok_len then
    return codec.error("INVALID_INPUT", err, { field = "Site-Id" })
  end
  local site = state.sites[msg["Site-Id"]]
  if not site then
    return codec.error("NOT_FOUND", "Site not registered", { siteId = msg["Site-Id"] })
  end
  return codec.ok {
    siteId = msg["Site-Id"],
    config = site.config,
    activeVersion = state.active_versions[msg["Site-Id"]],
  }
end

local gateway_status_allow = {
  online = true,
  offline = true,
  degraded = true,
  draining = true,
  maintenance = true,
}

local function normalize_host_label(value)
  if type(value) ~= "string" then
    return nil
  end
  return string.lower(value)
end

local function validate_gateway_id(value)
  local ok_type, err_type = validation.assert_type(value, "string", "Gateway-Id")
  if not ok_type then
    return false, err_type
  end
  local ok_len, err_len = validation.check_length(value, 128, "Gateway-Id")
  if not ok_len then
    return false, err_len
  end
  if not tostring(value):match "^[%w%-%._]+$" then
    return false, "invalid_format:Gateway-Id"
  end
  return true
end

local function validate_gateway_url(value)
  local ok_type, err_type = validation.assert_type(value, "string", "Url")
  if not ok_type then
    return false, err_type
  end
  local ok_len, err_len = validation.check_length(value, 512, "Url")
  if not ok_len then
    return false, err_len
  end
  if value:find "%s" then
    return false, "invalid_format:Url"
  end
  if not value:match "^https?://[%w]" then
    return false, "invalid_format:Url"
  end
  return true
end

local function validate_gateway_short_token(value, field, max_len)
  local ok_type, err_type = validation.assert_type(value, "string", field)
  if not ok_type then
    return false, err_type
  end
  local ok_len, err_len = validation.check_length(value, max_len, field)
  if not ok_len then
    return false, err_len
  end
  if not value:match "^[%w%-%._]+$" then
    return false, ("invalid_format:%s"):format(field)
  end
  return true
end

local function parse_gateway_numeric(value, field)
  local num = tonumber(value)
  if not num then
    return nil, ("invalid_number:%s"):format(field)
  end
  if num < 0 then
    return nil, ("invalid_number:%s"):format(field)
  end
  return num
end

local function validate_gateway_status(value)
  local ok_type, err_type = validation.assert_type(value, "string", "Status")
  if not ok_type then
    return false, err_type
  end
  local normalized = string.lower(value)
  if not gateway_status_allow[normalized] then
    return false, "invalid_value:Status"
  end
  return true, normalized
end

local function validate_gateway_last_seen(value)
  local ok_type, err_type = validation.assert_type(value, "string", "Last-Seen")
  if not ok_type then
    return false, err_type
  end
  local ok_len, err_len = validation.check_length(value, 64, "Last-Seen")
  if not ok_len then
    return false, err_len
  end
  if not value:match "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$" then
    return false, "invalid_format:Last-Seen"
  end
  return true
end

local function validate_gateway_domain_label(value, field, allow_wildcard)
  local normalized = normalize_host_label(value)
  if not normalized then
    return false, ("invalid_type:%s"):format(field)
  end
  local ok_len, err_len = validation.check_length(normalized, 255, field)
  if not ok_len then
    return false, err_len
  end
  if normalized:find "%s" or normalized:find "%.%.+" then
    return false, ("invalid_format:%s"):format(field)
  end
  if normalized:sub(1, 1) == "." or normalized:sub(-1) == "." then
    return false, ("invalid_format:%s"):format(field)
  end
  if normalized:find "%*" then
    if not allow_wildcard or not normalized:match "^%*%.[%w%-%.]+$" then
      return false, ("invalid_format:%s"):format(field)
    end
  elseif not normalized:match "^[%w%-%.]+$" then
    return false, ("invalid_format:%s"):format(field)
  end
  return true, normalized
end

local function normalize_gateway_domains(raw_domains)
  if raw_domains == nil then
    return {}
  end
  if type(raw_domains) == "string" then
    raw_domains = { raw_domains }
  end
  if type(raw_domains) ~= "table" then
    return nil, "Domains must be string or array", "Domains"
  end
  local seen = {}
  local out = {}
  for idx, domain in ipairs(raw_domains) do
    local ok_domain, norm_or_err =
      validate_gateway_domain_label(domain, ("Domains[%d]"):format(idx), true)
    if not ok_domain then
      return nil, norm_or_err, ("Domains[%d]"):format(idx)
    end
    local normalized = norm_or_err
    if not seen[normalized] then
      seen[normalized] = true
      out[#out + 1] = normalized
    end
  end
  table.sort(out)
  return out
end

local function snapshot_gateway(gateway)
  local domains = {}
  for i, domain in ipairs(gateway.domains or {}) do
    domains[i] = domain
  end
  return {
    id = gateway.id,
    url = gateway.url,
    region = gateway.region,
    country = gateway.country,
    capacityWeight = gateway.capacityWeight,
    score = gateway.score,
    status = gateway.status,
    lastSeen = gateway.lastSeen,
    domains = domains,
  }
end

local function host_matches_gateway_domain(host, domain)
  if host == domain then
    return true
  end
  if domain:sub(1, 2) ~= "*." then
    return false
  end
  local suffix = domain:sub(3)
  if host == suffix then
    return true
  end
  local tail = "." .. suffix
  return host:sub(-#tail) == tail
end

function handlers.RegisterGateway(msg)
  local required = {
    "Gateway-Id",
    "Url",
    "Region",
    "Country",
    "Capacity-Weight",
    "Score",
    "Status",
  }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Gateway-Id",
    "Url",
    "Region",
    "Country",
    "Capacity-Weight",
    "Score",
    "Status",
    "Last-Seen",
    "Domains",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_id, err_id = validate_gateway_id(msg["Gateway-Id"])
  if not ok_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Gateway-Id" })
  end
  local ok_url, err_url = validate_gateway_url(msg.Url)
  if not ok_url then
    return codec.error("INVALID_INPUT", err_url, { field = "Url" })
  end
  local ok_region, err_region = validate_gateway_short_token(msg.Region, "Region", 64)
  if not ok_region then
    return codec.error("INVALID_INPUT", err_region, { field = "Region" })
  end
  local ok_country, err_country = validate_gateway_short_token(msg.Country, "Country", 16)
  if not ok_country then
    return codec.error("INVALID_INPUT", err_country, { field = "Country" })
  end
  local capacity_weight, err_weight =
    parse_gateway_numeric(msg["Capacity-Weight"], "Capacity-Weight")
  if err_weight then
    return codec.error("INVALID_INPUT", err_weight, { field = "Capacity-Weight" })
  end
  local score, err_score = parse_gateway_numeric(msg.Score, "Score")
  if err_score then
    return codec.error("INVALID_INPUT", err_score, { field = "Score" })
  end
  local ok_status, status_or_err = validate_gateway_status(msg.Status)
  if not ok_status then
    return codec.error("INVALID_INPUT", status_or_err, { field = "Status" })
  end
  local status = status_or_err

  local last_seen = msg["Last-Seen"] or now_iso()
  local ok_seen, err_seen = validate_gateway_last_seen(last_seen)
  if not ok_seen then
    return codec.error("INVALID_INPUT", err_seen, { field = "Last-Seen" })
  end
  local domains, domains_err, domains_field = normalize_gateway_domains(msg.Domains)
  if not domains then
    return codec.error("INVALID_INPUT", domains_err, { field = domains_field or "Domains" })
  end

  local gateway_id = msg["Gateway-Id"]
  local existing = state.gateways[gateway_id]
  if existing then
    return codec.ok {
      gateway = snapshot_gateway(existing),
      note = "already_registered",
    }
  end

  local gateway = {
    id = gateway_id,
    url = msg.Url,
    region = msg.Region,
    country = msg.Country,
    capacityWeight = capacity_weight,
    score = score,
    status = status,
    lastSeen = last_seen,
    domains = domains,
  }
  state.gateways[gateway_id] = gateway
  audit.record("registry", "RegisterGateway", msg, nil, {
    gatewayId = gateway_id,
    status = status,
    domains = #domains,
  })
  return codec.ok { gateway = snapshot_gateway(gateway) }
end

function handlers.UpdateGatewayStatus(msg)
  local required = { "Gateway-Id" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Gateway-Id",
    "Status",
    "Score",
    "Capacity-Weight",
    "Last-Seen",
    "Domains",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_id, err_id = validate_gateway_id(msg["Gateway-Id"])
  if not ok_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Gateway-Id" })
  end
  local gateway = state.gateways[msg["Gateway-Id"]]
  if not gateway then
    return codec.error("NOT_FOUND", "Gateway not registered", { gatewayId = msg["Gateway-Id"] })
  end

  local has_update = msg.Status ~= nil
    or msg.Score ~= nil
    or msg["Capacity-Weight"] ~= nil
    or msg["Last-Seen"] ~= nil
    or msg.Domains ~= nil
  if not has_update then
    return codec.error("INVALID_INPUT", "No mutable fields supplied")
  end

  if msg.Status ~= nil then
    local ok_status, status_or_err = validate_gateway_status(msg.Status)
    if not ok_status then
      return codec.error("INVALID_INPUT", status_or_err, { field = "Status" })
    end
    gateway.status = status_or_err
  end
  if msg.Score ~= nil then
    local score, err_score = parse_gateway_numeric(msg.Score, "Score")
    if err_score then
      return codec.error("INVALID_INPUT", err_score, { field = "Score" })
    end
    gateway.score = score
  end
  if msg["Capacity-Weight"] ~= nil then
    local weight, err_weight = parse_gateway_numeric(msg["Capacity-Weight"], "Capacity-Weight")
    if err_weight then
      return codec.error("INVALID_INPUT", err_weight, { field = "Capacity-Weight" })
    end
    gateway.capacityWeight = weight
  end
  if msg["Last-Seen"] ~= nil then
    local ok_seen, err_seen = validate_gateway_last_seen(msg["Last-Seen"])
    if not ok_seen then
      return codec.error("INVALID_INPUT", err_seen, { field = "Last-Seen" })
    end
    gateway.lastSeen = msg["Last-Seen"]
  end
  if msg.Domains ~= nil then
    local domains, domains_err, domains_field = normalize_gateway_domains(msg.Domains)
    if not domains then
      return codec.error("INVALID_INPUT", domains_err, { field = domains_field or "Domains" })
    end
    gateway.domains = domains
  end

  audit.record("registry", "UpdateGatewayStatus", msg, nil, {
    gatewayId = gateway.id,
    status = gateway.status,
  })
  return codec.ok { gateway = snapshot_gateway(gateway) }
end

function handlers.ResolveGatewayForHost(msg)
  local required = { "Host" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Host is required", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Host",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_host, host_or_err = validate_gateway_domain_label(msg.Host, "Host", false)
  if not ok_host then
    return codec.error("INVALID_INPUT", host_or_err, { field = "Host" })
  end
  local host = host_or_err

  local candidates = {}
  for _, gateway in pairs(state.gateways) do
    if gateway.status == "online" then
      for _, domain in ipairs(gateway.domains or {}) do
        if host_matches_gateway_domain(host, domain) then
          candidates[#candidates + 1] = {
            gateway = gateway,
            matchedDomain = domain,
            score = tonumber(gateway.score) or 0,
            capacityWeight = tonumber(gateway.capacityWeight) or 0,
          }
          break
        end
      end
    end
  end

  if #candidates == 0 then
    return codec.error("NOT_FOUND", "No online gateway candidate for host", { host = host })
  end

  table.sort(candidates, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    if a.capacityWeight ~= b.capacityWeight then
      return a.capacityWeight > b.capacityWeight
    end
    return tostring(a.gateway.id) < tostring(b.gateway.id)
  end)

  local chosen = candidates[1]
  return codec.ok {
    host = host,
    matchedDomain = chosen.matchedDomain,
    gateway = snapshot_gateway(chosen.gateway),
  }
end

function handlers.ListGateways(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Status",
    "Host",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local status_filter = nil
  if msg.Status ~= nil then
    local ok_status, status_or_err = validate_gateway_status(msg.Status)
    if not ok_status then
      return codec.error("INVALID_INPUT", status_or_err, { field = "Status" })
    end
    status_filter = status_or_err
  end

  local host_filter = nil
  if msg.Host ~= nil then
    local ok_host, host_or_err = validate_gateway_domain_label(msg.Host, "Host", false)
    if not ok_host then
      return codec.error("INVALID_INPUT", host_or_err, { field = "Host" })
    end
    host_filter = host_or_err
  end

  local list = {}
  for _, gateway in pairs(state.gateways) do
    local include = true
    if status_filter and gateway.status ~= status_filter then
      include = false
    end
    if include and host_filter then
      include = false
      for _, domain in ipairs(gateway.domains or {}) do
        if host_matches_gateway_domain(host_filter, domain) then
          include = true
          break
        end
      end
    end
    if include then
      list[#list + 1] = snapshot_gateway(gateway)
    end
  end
  table.sort(list, function(a, b)
    return tostring(a.id) < tostring(b.id)
  end)

  return codec.ok {
    count = #list,
    gateways = list,
  }
end

function handlers.RegisterSite(msg)
  local ok, missing = validation.require_fields(msg, { "Site-Id" })
  if not ok then
    return codec.error("INVALID_INPUT", "Site-Id is required", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Site-Id",
    "Config",
    "Version",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_len, err = validation.check_length(msg["Site-Id"], 128, "Site-Id")
  if not ok_len then
    return codec.error("INVALID_INPUT", err, { field = "Site-Id" })
  end
  local config = msg.Config or {}
  if msg.Config ~= nil then
    local ok_type_cfg, err_type_cfg = validation.assert_type(msg.Config, "table", "Config")
    if not ok_type_cfg then
      return codec.error("INVALID_INPUT", err_type_cfg, { field = "Config" })
    end
    local ok_schema, schema_err = schema.validate("registryConfig", msg.Config)
    if not ok_schema then
      return codec.error("INVALID_INPUT", "Config failed schema", { errors = schema_err })
    end
  end
  local config_len = validation.estimate_json_length(config)
  local ok_size, err_size = validation.check_size(config_len, MAX_CONFIG_BYTES, "Config")
  if not ok_size then
    return codec.error("INVALID_INPUT", err_size, { field = "Config" })
  end
  local existing = state.sites[msg["Site-Id"]]
  if existing then
    return codec.ok {
      siteId = msg["Site-Id"],
      createdAt = existing.createdAt,
      config = existing.config,
      activeVersion = state.active_versions[msg["Site-Id"]],
      note = "already_registered",
    }
  end
  state.sites[msg["Site-Id"]] = {
    config = config,
    createdAt = now_iso(),
  }
  state.active_versions[msg["Site-Id"]] = config.version or msg.Version or nil
  audit.record("registry", "RegisterSite", msg, nil)
  return codec.ok {
    siteId = msg["Site-Id"],
    createdAt = state.sites[msg["Site-Id"]].createdAt,
    activeVersion = state.active_versions[msg["Site-Id"]],
  }
end

function handlers.BindDomain(msg)
  local required = { "Site-Id", "Host" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Site-Id",
    "Host",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_len_id, err_id = validation.check_length(msg["Site-Id"], 128, "Site-Id")
  if not ok_len_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Site-Id" })
  end
  local ok_len_host, err_host = validation.check_length(msg.Host, 255, "Host")
  if not ok_len_host then
    return codec.error("INVALID_INPUT", err_host, { field = "Host" })
  end
  if not state.sites[msg["Site-Id"]] then
    return codec.error("NOT_FOUND", "Site not registered", { siteId = msg["Site-Id"] })
  end
  state.domains[msg.Host] = msg["Site-Id"]
  audit.record("registry", "BindDomain", msg, nil, { host = msg.Host })
  return codec.ok {
    host = msg.Host,
    siteId = msg["Site-Id"],
  }
end

function handlers.SetActiveVersion(msg)
  local required = { "Site-Id", "Version" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Site-Id",
    "Version",
    "ExpectedVersion",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_len_id, err_id = validation.check_length(msg["Site-Id"], 128, "Site-Id")
  if not ok_len_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Site-Id" })
  end
  local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
  if not ok_len_ver then
    return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
  end
  if msg.ExpectedVersion then
    local ok_len_exp, err_exp = validation.check_length(msg.ExpectedVersion, 128, "ExpectedVersion")
    if not ok_len_exp then
      return codec.error("INVALID_INPUT", err_exp, { field = "ExpectedVersion" })
    end
  end
  if not state.sites[msg["Site-Id"]] then
    return codec.error("NOT_FOUND", "Site not registered", { siteId = msg["Site-Id"] })
  end
  local current = state.active_versions[msg["Site-Id"]]
  if msg.ExpectedVersion and current and current ~= msg.ExpectedVersion then
    return codec.error(
      "VERSION_CONFLICT",
      "ExpectedVersion mismatch",
      { expected = msg.ExpectedVersion, current = current }
    )
  end
  state.active_versions[msg["Site-Id"]] = msg.Version
  local resp = codec.ok {
    siteId = msg["Site-Id"],
    activeVersion = msg.Version,
  }
  audit.record("registry", "SetActiveVersion", msg, resp, { version = msg.Version })
  return resp
end

function handlers.GrantRole(msg)
  local required = { "Site-Id", "Subject", "Role" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Site-Id",
    "Subject",
    "Role",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_len_id, err_id = validation.check_length(msg["Site-Id"], 128, "Site-Id")
  if not ok_len_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Site-Id" })
  end
  local ok_len_subj, err_subj = validation.check_length(msg.Subject, 128, "Subject")
  if not ok_len_subj then
    return codec.error("INVALID_INPUT", err_subj, { field = "Subject" })
  end
  local ok_len_role, err_role = validation.check_length(msg.Role, 64, "Role")
  if not ok_len_role then
    return codec.error("INVALID_INPUT", err_role, { field = "Role" })
  end
  if not state.sites[msg["Site-Id"]] then
    return codec.error("NOT_FOUND", "Site not registered", { siteId = msg["Site-Id"] })
  end
  state.roles[msg["Site-Id"]] = state.roles[msg["Site-Id"]] or {}
  state.roles[msg["Site-Id"]][msg.Subject] = msg.Role
  audit.record("registry", "GrantRole", msg, nil, { subject = msg.Subject, role = msg.Role })
  return codec.ok {
    siteId = msg["Site-Id"],
    subject = msg.Subject,
    role = msg.Role,
  }
end

function handlers.UpdateTrustResolvers(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Manifest-Tx",
    "Resolvers",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  if msg.Resolvers and type(msg.Resolvers) ~= "table" then
    return codec.error("INVALID_INPUT", "Resolvers must be array")
  end
  local list = msg.Resolvers or {}
  state.trust.resolvers = list
  state.trust.manifestTx = msg["Manifest-Tx"]
  state.trust.updatedAt = now_iso()
  audit.record("registry", "UpdateTrustResolvers", msg, nil, { count = #list })
  return codec.ok {
    updatedAt = state.trust.updatedAt,
    count = #list,
    manifestTx = state.trust.manifestTx,
  }
end

function handlers.GetTrustedResolvers(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  return codec.ok {
    manifestTx = state.trust.manifestTx,
    updatedAt = state.trust.updatedAt,
    resolvers = state.trust.resolvers,
  }
end

local function release_key(component_id, version)
  return tostring(component_id) .. "@" .. tostring(version)
end

local function read_component_id(msg)
  return msg["Component-Id"] or "gateway"
end

local function validate_token_field(value, field, max_len, pattern)
  local ok_len, err_len = validation.check_length(value, max_len, field)
  if not ok_len then
    return false, err_len
  end
  local text = tostring(value)
  if text == "" then
    return false, ("invalid_format:%s"):format(field)
  end
  if pattern and not text:match(pattern) then
    return false, ("invalid_format:%s"):format(field)
  end
  return true
end

local function validate_iso8601_utc(value, field)
  local ok_len, err_len = validation.check_length(value, 64, field)
  if not ok_len then
    return false, err_len
  end
  if type(value) ~= "string" or not value:match "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$" then
    return false, ("invalid_format:%s"):format(field)
  end
  return true
end

local function validate_positive_integer(value, field)
  local num = tonumber(value)
  if not num or num <= 0 or num ~= math.floor(num) then
    return false, ("invalid_number:%s"):format(field)
  end
  return true, num
end

local function validate_integrity_release_fields(component_id, version, root, uri_hash, meta_hash)
  local ok_component, err_component =
    validate_token_field(component_id, "Component-Id", 96, "^[%w%-%._]+$")
  if not ok_component then
    return false, err_component, "Component-Id"
  end
  local ok_version, err_version = validate_token_field(version, "Version", 128, "^[%w%-%._]+$")
  if not ok_version then
    return false, err_version, "Version"
  end
  local ok_root, err_root = validate_token_field(root, "Root", 256, "^[%w%-%._]+$")
  if not ok_root then
    return false, err_root, "Root"
  end
  local ok_uri, err_uri = validate_token_field(uri_hash, "Uri-Hash", 256, "^[%w%-%._]+$")
  if not ok_uri then
    return false, err_uri, "Uri-Hash"
  end
  local ok_meta, err_meta = validate_token_field(meta_hash, "Meta-Hash", 256, "^[%w%-%._]+$")
  if not ok_meta then
    return false, err_meta, "Meta-Hash"
  end
  return true
end

local function parse_optional_number(value, field)
  if value == nil then
    return nil
  end
  local num = tonumber(value)
  if not num then
    return nil, ("invalid_number:%s"):format(field)
  end
  return num
end

local function parse_bool(value, field)
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    if value == 1 then
      return true
    end
    if value == 0 then
      return false
    end
  end
  if type(value) == "string" then
    local lower = string.lower(value)
    if lower == "1" or lower == "true" or lower == "yes" then
      return true
    end
    if lower == "0" or lower == "false" or lower == "no" then
      return false
    end
  end
  return nil, ("invalid_boolean:%s"):format(field)
end

local function get_active_release()
  local root = state.integrity.policy.activeRoot
  if not root then
    return nil
  end
  local key = state.integrity.roots[root]
  if not key then
    return nil
  end
  return state.integrity.releases[key]
end

function handlers.PublishTrustedRelease(msg)
  local required = { "Version", "Root", "Uri-Hash", "Meta-Hash" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Component-Id",
    "Version",
    "Root",
    "Uri-Hash",
    "Meta-Hash",
    "Published-At",
    "Activate",
    "Policy-Hash",
    "Max-CheckIn-Age-Sec",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local component_id = read_component_id(msg)
  local version = msg.Version
  local root = msg.Root
  local uri_hash = msg["Uri-Hash"]
  local meta_hash = msg["Meta-Hash"]
  local ok_fields, err_fields, err_field =
    validate_integrity_release_fields(component_id, version, root, uri_hash, meta_hash)
  if not ok_fields then
    return codec.error("INVALID_INPUT", err_fields, { field = err_field })
  end
  local published_at = msg["Published-At"] or now_iso()
  local ok_pub_len, err_pub_len = validate_iso8601_utc(published_at, "Published-At")
  if not ok_pub_len then
    return codec.error("INVALID_INPUT", err_pub_len, { field = "Published-At" })
  end
  local policy_hash = msg["Policy-Hash"]
  if policy_hash ~= nil then
    local ok_policy_len, err_policy_len =
      validate_token_field(policy_hash, "Policy-Hash", 256, "^[%w%-%._]+$")
    if not ok_policy_len then
      return codec.error("INVALID_INPUT", err_policy_len, { field = "Policy-Hash" })
    end
  end
  local max_age, err_max_age =
    parse_optional_number(msg["Max-CheckIn-Age-Sec"], "Max-CheckIn-Age-Sec")
  if err_max_age then
    return codec.error("INVALID_INPUT", err_max_age, { field = "Max-CheckIn-Age-Sec" })
  end
  if max_age and (max_age <= 0 or max_age ~= math.floor(max_age)) then
    return codec.error(
      "INVALID_INPUT",
      "invalid_number:Max-CheckIn-Age-Sec",
      { field = "Max-CheckIn-Age-Sec" }
    )
  end
  local activate, err_activate =
    parse_bool(msg.Activate == nil and true or msg.Activate, "Activate")
  if err_activate then
    return codec.error("INVALID_INPUT", err_activate, { field = "Activate" })
  end

  local key = release_key(component_id, version)
  local existing = state.integrity.releases[key]
  if existing then
    if existing.root ~= root or existing.uriHash ~= uri_hash or existing.metaHash ~= meta_hash then
      return codec.error(
        "VERSION_CONFLICT",
        "Version already published with different release data",
        {
          componentId = component_id,
          version = version,
        }
      )
    end
    return codec.ok {
      release = existing,
      activeRoot = state.integrity.policy.activeRoot,
      note = "already_published",
    }
  end

  local root_key = state.integrity.roots[root]
  if root_key and root_key ~= key then
    return codec.error("ROOT_CONFLICT", "Root already registered for a different release", {
      root = root,
      current = root_key,
      incoming = key,
    })
  end

  local release = {
    componentId = component_id,
    version = version,
    root = root,
    uriHash = uri_hash,
    metaHash = meta_hash,
    publishedAt = published_at,
  }
  state.integrity.releases[key] = release
  state.integrity.roots[root] = key

  if activate then
    state.integrity.active[component_id] = version
    state.integrity.policy.activeRoot = root
    if policy_hash and policy_hash ~= "" then
      state.integrity.policy.activePolicyHash = policy_hash
    end
    if max_age then
      state.integrity.policy.maxCheckInAgeSec = max_age
    end
    state.integrity.policy.updatedAt = now_iso()
  end

  audit.record("registry", "PublishTrustedRelease", msg, nil, {
    componentId = component_id,
    version = version,
    root = root,
    activate = activate,
  })
  return codec.ok {
    release = release,
    activated = activate,
    activeRoot = state.integrity.policy.activeRoot,
    activePolicyHash = state.integrity.policy.activePolicyHash,
  }
end

function handlers.RevokeTrustedRelease(msg)
  local has_root = msg.Root ~= nil
  local has_version = msg.Version ~= nil
  if not has_root and not has_version then
    return codec.error("INVALID_INPUT", "Root or Version is required")
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Component-Id",
    "Version",
    "Root",
    "Reason",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local component_id = read_component_id(msg)
  local key_from_version
  if has_version then
    local ok_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
    if not ok_ver then
      return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
    end
    key_from_version = release_key(component_id, msg.Version)
  end
  local key_from_root
  if has_root then
    local ok_root, err_root = validation.check_length(msg.Root, 256, "Root")
    if not ok_root then
      return codec.error("INVALID_INPUT", err_root, { field = "Root" })
    end
    key_from_root = state.integrity.roots[msg.Root]
  end
  if key_from_version and key_from_root and key_from_version ~= key_from_root then
    return codec.error("INVALID_INPUT", "Root and Version point to different releases")
  end

  local key = key_from_root or key_from_version
  local release = key and state.integrity.releases[key] or nil
  if not release then
    return codec.error("NOT_FOUND", "Trusted release not found", {
      componentId = component_id,
      version = msg.Version,
      root = msg.Root,
    })
  end

  local reason = msg.Reason or ""
  local ok_reason, err_reason = validation.check_length(reason, 512, "Reason")
  if not ok_reason then
    return codec.error("INVALID_INPUT", err_reason, { field = "Reason" })
  end

  if release.revokedAt then
    return codec.ok { release = release, note = "already_revoked" }
  end

  release.revokedAt = now_iso()
  release.revokedReason = reason
  if state.integrity.policy.activeRoot == release.root then
    state.integrity.policy.paused = true
    state.integrity.policy.pauseReason = "active_root_revoked"
    state.integrity.policy.pausedBy = msg["Actor-Role"]
    state.integrity.policy.pausedAt = now_iso()
    state.integrity.policy.updatedAt = now_iso()
  end

  audit.record("registry", "RevokeTrustedRelease", msg, nil, {
    componentId = release.componentId,
    version = release.version,
    root = release.root,
  })
  return codec.ok {
    release = release,
    paused = state.integrity.policy.paused,
    activeRoot = state.integrity.policy.activeRoot,
  }
end

function handlers.GetTrustedReleaseByVersion(msg)
  local required = { "Version" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Component-Id",
    "Version",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local component_id = read_component_id(msg)
  local key = release_key(component_id, msg.Version)
  local ok_component, err_component =
    validate_token_field(component_id, "Component-Id", 96, "^[%w%-%._]+$")
  if not ok_component then
    return codec.error("INVALID_INPUT", err_component, { field = "Component-Id" })
  end
  local ok_version, err_version = validate_token_field(msg.Version, "Version", 128, "^[%w%-%._]+$")
  if not ok_version then
    return codec.error("INVALID_INPUT", err_version, { field = "Version" })
  end
  local release = state.integrity.releases[key]
  if not release then
    return codec.error("NOT_FOUND", "Trusted release not found", {
      componentId = component_id,
      version = msg.Version,
    })
  end
  return codec.ok { release = release }
end

function handlers.GetTrustedReleaseByRoot(msg)
  local required = { "Root" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Root",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local key = state.integrity.roots[msg.Root]
  local ok_root, err_root = validate_token_field(msg.Root, "Root", 256, "^[%w%-%._]+$")
  if not ok_root then
    return codec.error("INVALID_INPUT", err_root, { field = "Root" })
  end
  local release = key and state.integrity.releases[key] or nil
  if not release then
    return codec.error("NOT_FOUND", "Trusted release not found", { root = msg.Root })
  end
  return codec.ok { release = release }
end

function handlers.GetTrustedRoot(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Component-Id",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local active_release = get_active_release()
  if not active_release then
    return codec.error("NOT_FOUND", "Active trusted root is not set")
  end
  return codec.ok {
    componentId = active_release.componentId,
    version = active_release.version,
    root = active_release.root,
    paused = state.integrity.policy.paused,
    activePolicyHash = state.integrity.policy.activePolicyHash,
  }
end

function handlers.SetIntegrityPolicyPause(msg)
  local required = { "Paused" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Paused",
    "Reason",
    "Policy-Hash",
    "Max-CheckIn-Age-Sec",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local paused, err_paused = parse_bool(msg.Paused, "Paused")
  if err_paused then
    return codec.error("INVALID_INPUT", err_paused, { field = "Paused" })
  end
  local reason = msg.Reason or ""
  local ok_reason, err_reason = validation.check_length(reason, 512, "Reason")
  if not ok_reason then
    return codec.error("INVALID_INPUT", err_reason, { field = "Reason" })
  end
  if msg["Policy-Hash"] ~= nil then
    local ok_policy_hash, err_policy_hash =
      validate_token_field(msg["Policy-Hash"], "Policy-Hash", 256, "^[%w%-%._]+$")
    if not ok_policy_hash then
      return codec.error("INVALID_INPUT", err_policy_hash, { field = "Policy-Hash" })
    end
    if msg["Policy-Hash"] ~= "" then
      state.integrity.policy.activePolicyHash = msg["Policy-Hash"]
    end
  end
  if msg["Max-CheckIn-Age-Sec"] ~= nil then
    local max_age, err_age =
      parse_optional_number(msg["Max-CheckIn-Age-Sec"], "Max-CheckIn-Age-Sec")
    if err_age then
      return codec.error("INVALID_INPUT", err_age, { field = "Max-CheckIn-Age-Sec" })
    end
    if max_age <= 0 or max_age ~= math.floor(max_age) then
      return codec.error(
        "INVALID_INPUT",
        "invalid_number:Max-CheckIn-Age-Sec",
        { field = "Max-CheckIn-Age-Sec" }
      )
    end
    state.integrity.policy.maxCheckInAgeSec = max_age
  end

  state.integrity.policy.paused = paused
  state.integrity.policy.updatedAt = now_iso()
  state.integrity.policy.pausedBy = msg["Actor-Role"]
  if paused then
    state.integrity.policy.pausedAt = now_iso()
    state.integrity.policy.pauseReason = reason
  else
    state.integrity.policy.pausedAt = nil
    state.integrity.policy.pauseReason = nil
  end

  audit.record("registry", "SetIntegrityPolicyPause", msg, nil, {
    paused = paused,
    reason = reason,
  })
  return codec.ok {
    paused = state.integrity.policy.paused,
    pauseReason = state.integrity.policy.pauseReason,
    pausedAt = state.integrity.policy.pausedAt,
    pausedBy = state.integrity.policy.pausedBy,
    activeRoot = state.integrity.policy.activeRoot,
    activePolicyHash = state.integrity.policy.activePolicyHash,
    maxCheckInAgeSec = state.integrity.policy.maxCheckInAgeSec,
    updatedAt = state.integrity.policy.updatedAt,
  }
end

function handlers.GetIntegrityPolicy(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  return codec.ok {
    activeRoot = state.integrity.policy.activeRoot,
    activePolicyHash = state.integrity.policy.activePolicyHash,
    paused = state.integrity.policy.paused,
    pausedAt = state.integrity.policy.pausedAt,
    pausedBy = state.integrity.policy.pausedBy,
    pauseReason = state.integrity.policy.pauseReason,
    maxCheckInAgeSec = state.integrity.policy.maxCheckInAgeSec,
    updatedAt = state.integrity.policy.updatedAt,
  }
end

function handlers.SetIntegrityAuthority(msg)
  local required = { "Root", "Upgrade", "Emergency", "Reporter" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Root",
    "Upgrade",
    "Emergency",
    "Reporter",
    "Signature-Refs",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local checks = {
    { field = "Root", value = msg.Root },
    { field = "Upgrade", value = msg.Upgrade },
    { field = "Emergency", value = msg.Emergency },
    { field = "Reporter", value = msg.Reporter },
  }
  for _, c in ipairs(checks) do
    local ok_len, err_len = validate_token_field(c.value, c.field, 256, "^[%w%-%._]+$")
    if not ok_len then
      return codec.error("INVALID_INPUT", err_len, { field = c.field })
    end
  end

  local signature_refs = msg["Signature-Refs"]
  if signature_refs == nil then
    signature_refs = { msg.Root }
  elseif type(signature_refs) == "string" then
    signature_refs = { signature_refs }
  elseif type(signature_refs) ~= "table" then
    return codec.error("INVALID_INPUT", "Signature-Refs must be string or array", {
      field = "Signature-Refs",
    })
  end
  if #signature_refs == 0 then
    return codec.error("INVALID_INPUT", "Signature-Refs cannot be empty", {
      field = "Signature-Refs",
    })
  end
  for idx, ref in ipairs(signature_refs) do
    local ok_ref, err_ref = validate_token_field(ref, "Signature-Refs", 256, "^[%w%-%._]+$")
    if not ok_ref then
      return codec.error("INVALID_INPUT", err_ref, { field = ("Signature-Refs[%d]"):format(idx) })
    end
  end

  state.integrity.authority.root = msg.Root
  state.integrity.authority.upgrade = msg.Upgrade
  state.integrity.authority.emergency = msg.Emergency
  state.integrity.authority.reporter = msg.Reporter
  state.integrity.authority.signatureRefs = signature_refs
  state.integrity.authority.updatedAt = now_iso()

  audit.record("registry", "SetIntegrityAuthority", msg, nil, {
    root = msg.Root,
    reporter = msg.Reporter,
    signatures = #signature_refs,
  })
  return codec.ok {
    root = state.integrity.authority.root,
    upgrade = state.integrity.authority.upgrade,
    emergency = state.integrity.authority.emergency,
    reporter = state.integrity.authority.reporter,
    signatureRefs = state.integrity.authority.signatureRefs,
    updatedAt = state.integrity.authority.updatedAt,
  }
end

function handlers.GetIntegrityAuthority(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  return codec.ok {
    root = state.integrity.authority.root,
    upgrade = state.integrity.authority.upgrade,
    emergency = state.integrity.authority.emergency,
    reporter = state.integrity.authority.reporter,
    signatureRefs = state.integrity.authority.signatureRefs,
    updatedAt = state.integrity.authority.updatedAt,
  }
end

function handlers.AppendIntegrityAuditCommitment(msg)
  local required = { "Seq-From", "Seq-To", "Merkle-Root", "Meta-Hash", "Reporter-Ref" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Seq-From",
    "Seq-To",
    "Merkle-Root",
    "Meta-Hash",
    "Reporter-Ref",
    "Accepted-At",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_seq_from, seq_from = validate_positive_integer(msg["Seq-From"], "Seq-From")
  if not ok_seq_from then
    return codec.error("INVALID_INPUT", seq_from, { field = "Seq-From" })
  end
  local ok_seq_to, seq_to = validate_positive_integer(msg["Seq-To"], "Seq-To")
  if not ok_seq_to then
    return codec.error("INVALID_INPUT", seq_to, { field = "Seq-To" })
  end
  if seq_to < seq_from then
    return codec.error("INVALID_INPUT", "Invalid audit sequence range", {
      seqFrom = seq_from,
      seqTo = seq_to,
    })
  end
  if state.integrity.audit.seqTo > 0 and seq_from <= state.integrity.audit.seqTo then
    return codec.error("VERSION_CONFLICT", "Audit sequence overlaps existing range", {
      currentSeqTo = state.integrity.audit.seqTo,
      seqFrom = seq_from,
      seqTo = seq_to,
    })
  end

  local fields = {
    { field = "Merkle-Root", value = msg["Merkle-Root"] },
    { field = "Meta-Hash", value = msg["Meta-Hash"] },
    { field = "Reporter-Ref", value = msg["Reporter-Ref"] },
  }
  for _, f in ipairs(fields) do
    local ok_len, err_len = validate_token_field(f.value, f.field, 256, "^[%w%-%._]+$")
    if not ok_len then
      return codec.error("INVALID_INPUT", err_len, { field = f.field })
    end
  end

  local accepted_at = msg["Accepted-At"] or now_iso()
  local ok_time, err_time = validate_iso8601_utc(accepted_at, "Accepted-At")
  if not ok_time then
    return codec.error("INVALID_INPUT", err_time, { field = "Accepted-At" })
  end

  state.integrity.audit.seqFrom = seq_from
  state.integrity.audit.seqTo = seq_to
  state.integrity.audit.merkleRoot = msg["Merkle-Root"]
  state.integrity.audit.metaHash = msg["Meta-Hash"]
  state.integrity.audit.reporterRef = msg["Reporter-Ref"]
  state.integrity.audit.acceptedAt = accepted_at

  audit.record("registry", "AppendIntegrityAuditCommitment", msg, nil, {
    seqFrom = seq_from,
    seqTo = seq_to,
  })
  return codec.ok {
    seqFrom = state.integrity.audit.seqFrom,
    seqTo = state.integrity.audit.seqTo,
    merkleRoot = state.integrity.audit.merkleRoot,
    metaHash = state.integrity.audit.metaHash,
    reporterRef = state.integrity.audit.reporterRef,
    acceptedAt = state.integrity.audit.acceptedAt,
  }
end

function handlers.GetIntegrityAuditState(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  return codec.ok {
    seqFrom = state.integrity.audit.seqFrom,
    seqTo = state.integrity.audit.seqTo,
    merkleRoot = state.integrity.audit.merkleRoot,
    metaHash = state.integrity.audit.metaHash,
    reporterRef = state.integrity.audit.reporterRef,
    acceptedAt = state.integrity.audit.acceptedAt,
  }
end

function handlers.GetIntegritySnapshot(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local active_release = get_active_release()
  if not active_release then
    return codec.error("NOT_FOUND", "Active trusted release is not set")
  end
  if active_release.revokedAt then
    return codec.error("NOT_FOUND", "Active trusted release is revoked", {
      root = active_release.root,
      revokedAt = active_release.revokedAt,
    })
  end

  return codec.ok {
    release = {
      componentId = active_release.componentId,
      version = active_release.version,
      root = active_release.root,
      uriHash = active_release.uriHash,
      metaHash = active_release.metaHash,
      publishedAt = active_release.publishedAt,
      revokedAt = active_release.revokedAt,
    },
    policy = {
      activeRoot = state.integrity.policy.activeRoot,
      activePolicyHash = state.integrity.policy.activePolicyHash,
      paused = state.integrity.policy.paused,
      maxCheckInAgeSec = state.integrity.policy.maxCheckInAgeSec,
    },
    authority = {
      root = state.integrity.authority.root,
      upgrade = state.integrity.authority.upgrade,
      emergency = state.integrity.authority.emergency,
      reporter = state.integrity.authority.reporter,
      signatureRefs = state.integrity.authority.signatureRefs,
    },
    audit = {
      seqFrom = state.integrity.audit.seqFrom,
      seqTo = state.integrity.audit.seqTo,
      merkleRoot = state.integrity.audit.merkleRoot,
      metaHash = state.integrity.audit.metaHash,
      reporterRef = state.integrity.audit.reporterRef,
      acceptedAt = state.integrity.audit.acceptedAt,
    },
  }
end

local function validate_resolver_id(id)
  local ok_len, err = validation.check_length(id, 256, "Resolver-Id")
  if not ok_len then
    return false, err
  end
  return true
end

function handlers.FlagResolver(msg)
  local required = { "Resolver-Id", "Flag" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Resolver-Id",
    "Flag",
    "Reason",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_id, err_id = validate_resolver_id(msg["Resolver-Id"])
  if not ok_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Resolver-Id" })
  end
  local flag = msg.Flag
  if flag ~= "suspicious" and flag ~= "blocked" and flag ~= "ok" then
    return codec.error("INVALID_INPUT", "Flag must be suspicious|blocked|ok", { flag = flag })
  end
  local reason = msg.Reason or ""
  local ok_len_reason, err_reason = validation.check_length(reason, 512, "Reason")
  if not ok_len_reason then
    return codec.error("INVALID_INPUT", err_reason, { field = "Reason" })
  end
  state.resolver_flags[msg["Resolver-Id"]] = {
    flag = flag,
    reason = reason,
    raisedAt = now_iso(),
    raisedBy = msg["Actor-Role"],
  }
  persist_flag_event {
    ts = now_iso(),
    action = "FlagResolver",
    resolverId = msg["Resolver-Id"],
    flag = flag,
    reason = reason,
  }
  audit.record("registry", "FlagResolver", msg, nil, { resolver = msg["Resolver-Id"], flag = flag })
  return codec.ok { resolverId = msg["Resolver-Id"], flag = flag, reason = reason }
end

function handlers.UnflagResolver(msg)
  local required = { "Resolver-Id" }
  local ok, missing = validation.require_fields(msg, required)
  if not ok then
    return codec.error("INVALID_INPUT", "Missing required field", { missing = missing })
  end
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Resolver-Id",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  local ok_id, err_id = validate_resolver_id(msg["Resolver-Id"])
  if not ok_id then
    return codec.error("INVALID_INPUT", err_id, { field = "Resolver-Id" })
  end
  state.resolver_flags[msg["Resolver-Id"]] = nil
  persist_flag_event {
    ts = now_iso(),
    action = "UnflagResolver",
    resolverId = msg["Resolver-Id"],
    flag = "cleared",
  }
  audit.record("registry", "UnflagResolver", msg, nil, { resolver = msg["Resolver-Id"] })
  return codec.ok { resolverId = msg["Resolver-Id"], flag = "cleared" }
end

function handlers.GetResolverFlags(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Nonce",
    "ts",
    "Timestamp",
    "Resolver-Id",
    "Actor-Role",
    "Schema-Version",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end
  if msg["Resolver-Id"] then
    local ok_id, err_id = validate_resolver_id(msg["Resolver-Id"])
    if not ok_id then
      return codec.error("INVALID_INPUT", err_id, { field = "Resolver-Id" })
    end
    local entry = state.resolver_flags[msg["Resolver-Id"]]
    if not entry then
      return codec.ok { resolverId = msg["Resolver-Id"], flag = "none" }
    end
    return codec.ok {
      resolverId = msg["Resolver-Id"],
      flag = entry.flag,
      reason = entry.reason,
      raisedAt = entry.raisedAt,
      raisedBy = entry.raisedBy,
    }
  end
  local cnt = 0
  for _ in pairs(state.resolver_flags) do
    cnt = cnt + 1
  end
  return codec.ok { flags = state.resolver_flags, count = cnt }
end

local function route(msg)
  local ok, missing = validation.require_tags(msg, { "Action" })
  if not ok then
    return codec.missing_tags(missing)
  end

  local ok_sec, sec_err = auth.enforce(msg)
  if not ok_sec then
    return codec.error("FORBIDDEN", sec_err)
  end

  local seen = idem.check(msg["Request-Id"])
  if seen then
    return seen
  end

  local ok_action, err = validation.require_action(msg, allowed_actions)
  if not ok_action then
    if err == "unknown_action" then
      return codec.unknown_action(msg.Action)
    end
    return codec.error("MISSING_ACTION", "Action is required")
  end

  local ok_hmac, hmac_err =
    auth.verify_outbox_hmac_for_action(msg, { skip_for = hmac_skip_actions })
  if not ok_hmac then
    return codec.error("FORBIDDEN", hmac_err)
  end

  local ok_role, role_err = auth.require_role_for_action(msg, role_policy)
  if not ok_role then
    return codec.error("FORBIDDEN", role_err)
  end

  local handler = handlers[msg.Action]
  if not handler then
    return codec.unknown_action(msg.Action)
  end

  local resp = handler(msg)
  metrics.inc("registry." .. msg.Action .. ".count")
  metrics.tick()
  idem.record(msg["Request-Id"], resp)
  persist.save("registry_state", state)
  return resp
end

local function is_array(value)
  if type(value) ~= "table" then
    return false, 0
  end
  local max = 0
  local count = 0
  for k in pairs(value) do
    if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then
      return false, 0
    end
    if k > max then
      max = k
    end
    count = count + 1
  end
  if max == 0 then
    return true, 0
  end
  if max ~= count then
    return false, 0
  end
  return true, max
end

local function json_quote(value)
  local s = tostring(value)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return '"' .. s .. '"'
end

local function encode_json_fallback(value, seen)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    return value and "true" or "false"
  end
  if t == "number" then
    if value ~= value or value == math.huge or value == -math.huge then
      return "null"
    end
    return tostring(value)
  end
  if t == "string" then
    return json_quote(value)
  end
  if t ~= "table" then
    return json_quote(tostring(value))
  end
  seen = seen or {}
  if seen[value] then
    return json_quote "__cycle__"
  end
  seen[value] = true
  local out = {}
  local array_like, length = is_array(value)
  if array_like then
    for i = 1, length do
      out[#out + 1] = encode_json_fallback(value[i], seen)
    end
    seen[value] = nil
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  for _, key in ipairs(keys) do
    out[#out + 1] = json_quote(tostring(key)) .. ":" .. encode_json_fallback(value[key], seen)
  end
  seen[value] = nil
  return "{" .. table.concat(out, ",") .. "}"
end

local function encode_json(value)
  if json_ok and json then
    local ok, encoded = pcall(json.encode, value)
    if ok and type(encoded) == "string" then
      return encoded
    end
  end
  return encode_json_fallback(value, {})
end

local function tag_value(tags, key)
  if type(tags) ~= "table" then
    return nil
  end
  if tags[key] ~= nil then
    return tags[key]
  end
  if tags[key:lower()] ~= nil then
    return tags[key:lower()]
  end
  for _, entry in ipairs(tags) do
    if type(entry) == "table" and (entry.name == key or entry.Name == key) then
      return entry.value or entry.Value
    end
  end
  return nil
end

local function parse_json_object(raw)
  if type(raw) == "table" then
    return raw
  end
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local ok, decoded = pcall(function()
    if json_ok and json then
      return json.decode(raw)
    end
    return nil
  end)
  if ok and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function merge_string_keys(dst, src)
  if type(src) ~= "table" then
    return
  end
  for key, value in pairs(src) do
    if type(key) == "string" and dst[key] == nil then
      dst[key] = value
    end
  end
end

local function merge_tag_keys(dst, tags)
  if type(tags) ~= "table" then
    return
  end
  merge_string_keys(dst, tags)
  for _, entry in ipairs(tags) do
    if type(entry) == "table" then
      local name = entry.name or entry.Name
      local value = entry.value or entry.Value
      if type(name) == "string" and dst[name] == nil and value ~= nil then
        dst[name] = value
      end
    end
  end
end

local function enrich_message(msg)
  local envelope = (type(msg) == "table" and (msg.Body or msg.body)) or {}
  local tags = msg.Tags or msg.tags or envelope.Tags or envelope.tags or {}
  local data_obj = parse_json_object(msg.Data or msg.data)
    or parse_json_object(envelope.Data or envelope.data)
    or {}

  local out = {}
  merge_string_keys(out, data_obj)
  merge_string_keys(out, envelope)
  merge_string_keys(out, msg)
  merge_tag_keys(out, tags)

  out.Action = out.Action or out.action or tag_value(tags, "Action")
  out["Request-Id"] = out["Request-Id"] or out.requestId or tag_value(tags, "Request-Id")
  out["Actor-Role"] = out["Actor-Role"] or out.actorRole or tag_value(tags, "Actor-Role")
  out["Schema-Version"] = out["Schema-Version"]
    or out.schemaVersion
    or tag_value(tags, "Schema-Version")
  out.Signature = out.Signature or out.signature or tag_value(tags, "Signature")
  out.Nonce = out.Nonce or out.nonce or tag_value(tags, "Nonce")
  out.ts = out.ts or out.timestamp or tag_value(tags, "ts")
  out.From = msg.From or msg.from
  out.Tags = tags
  return out, tags
end

local function emit_response_json(json_text)
  pcall(function()
    if type(print) == "function" then
      print(json_text)
    end
  end)
  return json_text
end

local function handle_registry_action(msg)
  local normalized = enrich_message(msg or {})
  local ok_route, route_result = pcall(route, normalized)
  local resp = ok_route and route_result
    or codec.error("HANDLER_CRASH", tostring(route_result or "registry_handler_crash"))
  local resp_json = encode_json(resp)
  return emit_response_json(resp_json)
end

local function is_registry_action(msg)
  if type(msg) ~= "table" then
    return false
  end
  local normalized = enrich_message(msg)
  local action = normalized.Action
  return type(action) == "string" and handlers[action] ~= nil
end

local registry_handler_registered = false
local registry_evaluate_wrapped = false
local original_handlers_evaluate = nil
local function ensure_registry_evaluate_wrapped(handlers_api)
  local api = handlers_api
  if type(api) ~= "table" then
    api = Handlers
  end
  if type(api) ~= "table" or type(api.evaluate) ~= "function" then
    return false
  end
  if not registry_evaluate_wrapped then
    original_handlers_evaluate = api.evaluate
    api.evaluate = function(msg, env)
      if is_registry_action(msg) then
        return handle_registry_action(msg)
      end
      return original_handlers_evaluate(msg, env)
    end
    registry_evaluate_wrapped = true
  end
  return true
end

local function ensure_registry_handler_registered()
  local handlers_api = Handlers
  if type(handlers_api) ~= "table" or type(handlers_api.add) ~= "function" then
    local ok_handlers, resolved_handlers = pcall(require, ".handlers")
    if
      ok_handlers
      and type(resolved_handlers) == "table"
      and type(resolved_handlers.add) == "function"
    then
      handlers_api = resolved_handlers
      Handlers = resolved_handlers
    else
      return false
    end
  end

  if not registry_handler_registered then
    handlers_api.add("Registry-Action", is_registry_action, handle_registry_action)
    registry_handler_registered = true
  end
  ensure_registry_evaluate_wrapped(handlers_api)
  return true
end

ensure_registry_handler_registered()

local function fallback_handle(msg)
  ensure_registry_handler_registered()
  if is_registry_action(msg) then
    return handle_registry_action(msg)
  end
  return nil
end

local previous_Handle = _G.Handle
local previous_handle = _G.handle

local function emit_handler_error(code, message, meta)
  return emit_response_json(encode_json(codec.error(code, message, meta)))
end

local function merged_global_handle(original, msg)
  local routed = fallback_handle(msg)
  if routed ~= nil then
    return routed
  end
  if type(original) == "function" then
    local ok_original, original_result = pcall(original, msg)
    if ok_original then
      return original_result
    else
      return emit_handler_error(
        "HANDLER_CRASH",
        tostring(original_result or "registry_original_handle_crash")
      )
    end
  end
  return nil
end

_G.Handle = function(msg)
  return merged_global_handle(previous_Handle, msg)
end

_G.handle = function(msg)
  local original = previous_handle
  if type(original) ~= "function" then
    original = previous_Handle
  end
  return merged_global_handle(original, msg)
end

return {
  route = route,
  _state = state, -- exposed for tests
}
]====], "ao.registry.process")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.site.process"] = function()
      local loaded, err = load([====[-- Site process handlers: routes, pages, layouts, navigation.
    
    local codec = require "ao.shared.codec"
    local validation = require "ao.shared.validation"
    local ids = require "ao.shared.ids"
    local ar = require "ao.shared.arweave"
    local auth = require "ao.shared.auth"
    local idem = require "ao.shared.idempotency"
    local audit = require "ao.shared.audit"
    local metrics = require "ao.shared.metrics"
    local schema = require "ao.shared.schema"
    local assets = require "ao.shared.assets"
    local a11y = require "ao.shared.a11y"
    local i18n = require "ao.shared.i18n"
    local layout_components = require "ao.shared.layout_components"
    local persist = require "ao.shared.persist"
    
    local handlers = {}
    local allowed_actions = {
      "ResolveRoute",
      "GetPage",
      "GetLayout",
      "GetNavigation",
      "PutDraft",
      "AddDraftComment",
      "RequestPublish",
      "ApprovePublish",
      "SchedulePublish",
      "RunPublishScheduler",
      "LockDraft",
      "UnlockDraft",
      "ForceUnlockDraft",
      "RenewDraftLock",
      "GetDraftAudit",
      "RegisterContentType",
      "ListContentTypes",
      "SetPerfBudgets",
      "RecordWebVital",
      "UpsertRoute",
      "UpsertLayout",
      "RegisterAsset",
      "GetAsset",
      "SetLocales",
      "PublishVersion",
      "ArchivePage",
      "GenerateSitemap",
      "GenerateRobots",
      "RecordOrder",
      "GetOrder",
      "ListOrders",
      "GetPublishLog",
      "ExportPublishLog",
      "GetPublishStatus",
    }
    
    local role_policy = {
      PutDraft = { "editor", "publisher", "admin" },
      AddDraftComment = { "editor", "publisher", "admin" },
      RequestPublish = { "editor", "publisher", "admin" },
      ApprovePublish = { "publisher", "admin" },
      SchedulePublish = { "publisher", "admin" },
      RunPublishScheduler = { "publisher", "admin" },
      LockDraft = { "editor", "publisher", "admin" },
      UnlockDraft = { "editor", "publisher", "admin" },
      ForceUnlockDraft = { "publisher", "admin" },
      RenewDraftLock = { "editor", "publisher", "admin" },
      GetDraftAudit = { "editor", "publisher", "admin", "support" },
      RegisterContentType = { "admin" },
      ListContentTypes = { "editor", "publisher", "admin" },
      SetPerfBudgets = { "admin" },
      RecordWebVital = { "viewer", "support", "editor", "publisher", "admin" },
      UpsertRoute = { "editor", "publisher", "admin" },
      UpsertLayout = { "editor", "publisher", "admin" },
      RegisterAsset = { "editor", "publisher", "admin" },
      GetAsset = { "editor", "publisher", "admin", "support" },
      SetLocales = { "admin", "publisher" },
      PublishVersion = { "publisher", "admin" },
      ArchivePage = { "publisher", "admin" },
      GenerateSitemap = { "publisher", "admin" },
      GenerateRobots = { "publisher", "admin" },
      RecordOrder = { "support", "admin" },
      GetOrder = { "support", "admin" },
      ListOrders = { "support", "admin" },
      GetPublishLog = { "publisher", "admin", "support" },
      ExportPublishLog = { "admin" },
      GetPublishStatus = { "publisher", "admin", "support" },
    }
    
    -- pseudo-state for scaffolding
    local state = persist.load("site_state", {
      routes = {}, -- route:<site>:<path>[:locale] -> { pageId, layoutId, type }
      pages = {}, -- page:<site>:<page>:<version>[:locale] -> { content, manifestTx, archived }
      layouts = {}, -- layout:<id>:<version>[:locale] -> { content }
      menus = {}, -- menu:<site>:<menu>:<version>[:locale] -> { items }
      drafts = {}, -- page:<site>:<page>:draft[:locale] -> { content }
      active_versions = {}, -- siteId -> versionId
      orders = {}, -- siteId -> orderId -> { status, totalAmount, currency, vatRate, updatedAt }
      assets = {}, -- siteId -> assetId -> metadata
      locales = {}, -- siteId -> { default = "en", supported = { "en" } }
      draft_comments = {}, -- draftKey -> { { author, body, ts } }
      draft_locks = {}, -- draftKey -> { subject, ts, ttl }
      publish_schedules = {}, -- siteId -> list { pageId, version, locale, publishAt, expireAt }
      content_types = {}, -- siteId -> { name -> schema }
      perf_budgets = {}, -- siteId -> { lcp_ms, cls, tbt_ms }
      perf_vitals = {}, -- siteId -> { last = { metric, value, ts } }
      publish_log = {}, -- list of publish/expire actions for observability
      draft_audit = {}, -- draftId -> { { ts, fields, actor } }
    })
    
    local MAX_CONTENT_BYTES = tonumber(os.getenv "SITE_MAX_CONTENT_BYTES" or "") or (64 * 1024)
    local MAX_PUBLISH_RETRY = tonumber(os.getenv "SITE_MAX_PUBLISH_RETRY" or "") or 5
    local PUBLISH_LOG_LIMIT = tonumber(os.getenv "SITE_PUBLISH_LOG_LIMIT" or "") or 1000
    local PUBLISH_ALERT_PATH = os.getenv "SITE_PUBLISH_ALERT_PATH"
    local PUBLISH_ALERT_WEBHOOK = os.getenv "SITE_PUBLISH_ALERT_WEBHOOK"
    local CACHE_TTL = tonumber(os.getenv "SITE_CACHE_TTL" or "") or 30
    local CACHE_STALE_TTL = tonumber(os.getenv "SITE_CACHE_STALE_TTL" or "") or 300
    local CACHE_STALE_WHILE_REVALIDATE = CACHE_STALE_TTL > CACHE_TTL and (CACHE_STALE_TTL - CACHE_TTL)
      or 0
    local ENABLE_CACHE_HEADERS = os.getenv "SITE_CACHE_HEADERS" == "1"
    
    local cache_store = {}
    local inflight = {}
    
    local function cache_key(action, key)
      return action .. ":" .. key
    end
    
    local function cache_get(action, key)
      local entry = cache_store[cache_key(action, key)]
      if not entry then
        return nil
      end
      local age = os.time() - entry.ts
      if age <= CACHE_TTL then
        return entry.value, false
      end
      if age <= CACHE_STALE_TTL then
        return entry.value, true
      end
      cache_store[cache_key(action, key)] = nil
      return nil
    end
    
    local function cache_put(action, key, value)
      cache_store[cache_key(action, key)] = { value = value, ts = os.time() }
    end
    
    local function cache_purge(predicate)
      for k, _ in pairs(cache_store) do
        if predicate(k) then
          cache_store[k] = nil
        end
      end
    end
    
    local function cache_purge_site(site_id)
      cache_purge(function(k)
        return k:find(site_id, 1, true) ~= nil
      end)
    end
    
    local function cache_purge_match(fragment)
      if not fragment or fragment == "" then
        return
      end
      cache_purge(function(k)
        return k:find(fragment, 1, true) ~= nil
      end)
    end
    
    local function with_cache(action, key, fetch_fn)
      local cached, stale = cache_get(action, key)
      if cached then
        metrics.inc(stale and "ao_cache_stale_hit" or "ao_cache_hit")
        cached.cache = cached.cache or {}
        cached.cache.hit = true
        cached.cache.stale = stale
        cached.cache.maxAge = CACHE_TTL
        cached.cache.staleWhileRevalidate = CACHE_STALE_WHILE_REVALIDATE
        cached.cache.staleIfError = CACHE_STALE_TTL
        if ENABLE_CACHE_HEADERS then
          cached.headers = cached.headers or {}
          cached.headers["Cache-Control"] = string.format(
            "public, max-age=%d, stale-while-revalidate=%d, stale-if-error=%d",
            CACHE_TTL,
            CACHE_STALE_WHILE_REVALIDATE,
            CACHE_STALE_TTL
          )
        end
        return codec.ok(cached)
      end
      if inflight[cache_key(action, key)] then
        local inflight_cached = cache_get(action, key)
        if inflight_cached then
          metrics.inc "ao_cache_stale_hit"
          inflight_cached.cache = inflight_cached.cache or {}
          inflight_cached.cache.hit = true
          inflight_cached.cache.stale = true
          inflight_cached.cache.single_flight = true
          inflight_cached.cache.maxAge = CACHE_TTL
          inflight_cached.cache.staleWhileRevalidate = CACHE_STALE_WHILE_REVALIDATE
          inflight_cached.cache.staleIfError = CACHE_STALE_TTL
          return codec.ok(inflight_cached)
        end
      end
      inflight[cache_key(action, key)] = true
      local ok, result = fetch_fn()
      inflight[cache_key(action, key)] = nil
      if not ok then
        local stale_val = cache_get(action, key)
        if stale_val then
          metrics.inc "ao_cache_stale_fallback"
          stale_val.cache = stale_val.cache or {}
          stale_val.cache.hit = true
          stale_val.cache.stale = true
          stale_val.cache.fallback = true
          stale_val.cache.maxAge = CACHE_TTL
          stale_val.cache.staleWhileRevalidate = CACHE_STALE_WHILE_REVALIDATE
          stale_val.cache.staleIfError = CACHE_STALE_TTL
          return codec.ok(stale_val)
        end
        return result
      end
      cache_put(action, key, result)
      metrics.inc "ao_cache_miss"
      result.cache = result.cache or {}
      result.cache.hit = false
      result.cache.stale = false
      result.cache.maxAge = CACHE_TTL
      result.cache.staleWhileRevalidate = CACHE_STALE_WHILE_REVALIDATE
      result.cache.staleIfError = CACHE_STALE_TTL
      if ENABLE_CACHE_HEADERS then
        result.headers = result.headers or {}
        result.headers["Cache-Control"] = string.format(
          "public, max-age=%d, stale-while-revalidate=%d, stale-if-error=%d",
          CACHE_TTL,
          CACHE_STALE_WHILE_REVALIDATE,
          CACHE_STALE_TTL
        )
      end
      return codec.ok(result)
    end
    
    local function publish_alert(entry, msg)
      local payload = require("cjson").encode {
        ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
        entry = entry,
        message = msg,
        retryCount = entry.retryCount,
        lastError = entry.lastError,
      }
      if PUBLISH_ALERT_PATH then
        local f = io.open(PUBLISH_ALERT_PATH, "a")
        if f then
          f:write(payload, "\n")
          f:close()
        end
      end
      if PUBLISH_ALERT_WEBHOOK and PUBLISH_ALERT_WEBHOOK ~= "" then
        local cmd = string.format(
          "curl -s -X POST -H 'Content-Type: application/json' --data %q %s >/dev/null 2>&1",
          payload,
          PUBLISH_ALERT_WEBHOOK
        )
        os.execute(cmd)
      end
    end
    
    local function get_locale_cfg(site_id)
      return state.locales[site_id] or { default = "en", supported = { "en" } }
    end
    
    local function pick_locale(site_id, requested)
      local cfg = get_locale_cfg(site_id)
      if not requested or requested == "" then
        return cfg.default
      end
      for _, loc in ipairs(cfg.supported or {}) do
        if loc:lower() == requested:lower() then
          return loc:lower()
        end
      end
      return cfg.default
    end
    
    local function validate_locales(msg)
      local supported = msg.Locales or { msg["Default-Locale"] or "en" }
      local default_locale = (msg["Default-Locale"] or supported[1]):lower()
      if #supported == 0 or #supported > 16 then
        return nil, nil, "Locales must contain 1-16 entries"
      end
      for _, loc in ipairs(supported) do
        local ok_len_loc, err_loc = validation.check_length(loc, 10, "Locales")
        if not ok_len_loc then
          return nil, nil, err_loc
        end
        if not loc:match "^[A-Za-z][A-Za-z%-]*$" then
          return nil, nil, "Locale must be alpha/alpha-dash"
        end
      end
      local found_default = false
      for _, loc in ipairs(supported) do
        if loc:lower() == default_locale then
          found_default = true
          break
        end
      end
      if not found_default then
        return nil, nil, "Default-Locale must be listed in Locales"
      end
      return supported, default_locale
    end
    
    function handlers.ResolveRoute(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Path" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Path", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_path, err_path = validation.check_length(msg.Path, 2048, "Path")
      if not ok_len_path then
        return codec.error("INVALID_INPUT", err_path, { field = "Path" })
      end
      local locale_cfg = get_locale_cfg(msg["Site-Id"])
      local locale, normalized_path =
        i18n.detect_locale(msg.Path, locale_cfg.supported, locale_cfg.default)
      local key_locale = ids.route_key(msg["Site-Id"], normalized_path, locale)
      local key_default = ids.route_key(msg["Site-Id"], normalized_path, locale_cfg.default)
      local key_plain = ids.route_key(msg["Site-Id"], normalized_path)
      local cache_id = table.concat({ msg["Site-Id"], normalized_path, locale }, "|")
      return with_cache("ResolveRoute", cache_id, function()
        local route = state.routes[key_locale] or state.routes[key_default] or state.routes[key_plain]
        if not route then
          return false, codec.error("NOT_FOUND", "Route not found", { path = msg.Path })
        end
        local perf = state.perf_vitals[msg["Site-Id"]]
        local budgets = state.perf_budgets[msg["Site-Id"]]
        if perf and budgets then
          if perf.metric == "LCP" and budgets.lcp_ms and perf.value > budgets.lcp_ms then
            return false, codec.error("PERF_BUDGET_EXCEEDED", "LCP over budget", { lcp = perf.value })
          end
          if perf.metric == "CLS" and budgets.cls and perf.value > budgets.cls then
            return false, codec.error("PERF_BUDGET_EXCEEDED", "CLS over budget", { cls = perf.value })
          end
          if perf.metric == "TBT" and budgets.tbt_ms and perf.value > budgets.tbt_ms then
            return false, codec.error("PERF_BUDGET_EXCEEDED", "TBT over budget", { tbt = perf.value })
          end
        end
        local cache_policy = state.edge_cache
          and state.edge_cache[msg["Site-Id"]]
          and state.edge_cache[msg["Site-Id"]][route.path or msg.Path]
        metrics.inc "site.ResolveRoute.count"
        metrics.tick()
        return true,
          {
            siteId = msg["Site-Id"],
            path = msg.Path,
            locale = locale,
            pageId = route.pageId,
            layoutId = route.layoutId,
            type = route.type or "page",
            cache = cache_policy,
            warnings = route.warnings,
          }
      end)
    end
    
    function handlers.GetPage(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Page-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Page-Id",
        "Version",
        "Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_page, err_page = validation.check_length(msg["Page-Id"], 128, "Page-Id")
      if not ok_len_page then
        return codec.error("INVALID_INPUT", err_page, { field = "Page-Id" })
      end
      if msg.Version then
        local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
        if not ok_len_ver then
          return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
        end
      end
      local version = msg.Version or state.active_versions[msg["Site-Id"]] or "active"
      local locale = pick_locale(msg["Site-Id"], msg.Locale)
      local cache_id = table.concat({ msg["Site-Id"], msg["Page-Id"], version, locale }, "|")
      return with_cache("GetPage", cache_id, function()
        local key = ids.page_key(msg["Site-Id"], msg["Page-Id"], version, locale)
        local fallback = ids.page_key(msg["Site-Id"], msg["Page-Id"], version)
        local page = state.pages[key] or state.pages[fallback]
        if not page or page.archived then
          return false,
            codec.error("NOT_FOUND", "Page not found", { pageId = msg["Page-Id"], version = version })
        end
        -- enforce lazy/blur defaults on returned blocks (non-destructive)
        local content = page.content
        if content and content.blocks then
          for _, block in ipairs(content.blocks) do
            if type(block) == "table" and block.image and type(block.image) == "table" then
              block.image.loading = block.image.loading or "lazy"
              block.image.placeholder = block.image.placeholder or "blur"
            end
          end
        end
        return true,
          {
            siteId = msg["Site-Id"],
            pageId = msg["Page-Id"],
            version = version,
            locale = locale,
            content = content,
            warnings = page.warnings,
          }
      end)
    end
    
    function handlers.GetLayout(msg)
      local ok, missing = validation.require_fields(msg, { "Layout-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Layout-Id",
        "Version",
        "Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_layout, err_layout = validation.check_length(msg["Layout-Id"], 128, "Layout-Id")
      if not ok_len_layout then
        return codec.error("INVALID_INPUT", err_layout, { field = "Layout-Id" })
      end
      if msg.Version then
        local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
        if not ok_len_ver then
          return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
        end
      end
      local version = msg.Version or "active"
      local locale = msg.Locale and msg.Locale:lower() or nil
      local cache_id = table.concat({ msg["Layout-Id"], version, locale or "" }, "|")
      return with_cache("GetLayout", cache_id, function()
        local key = ids.layout_key(msg["Layout-Id"], version, locale)
        local fallback = ids.layout_key(msg["Layout-Id"], version)
        local layout = state.layouts[key] or state.layouts[fallback]
        if not layout then
          return false,
            codec.error(
              "NOT_FOUND",
              "Layout not found",
              { layoutId = msg["Layout-Id"], version = version }
            )
        end
        if layout.content then
          for _, comp in ipairs(layout.content) do
            if comp.image then
              comp.image.loading = comp.image.loading or "lazy"
              comp.image.placeholder = comp.image.placeholder or "blur"
            end
          end
        end
        return true,
          {
            layoutId = msg["Layout-Id"],
            version = version,
            locale = locale or nil,
            content = layout.content,
            warnings = layout.warnings,
          }
      end)
    end
    
    function handlers.GetNavigation(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Menu-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Menu-Id",
        "Version",
        "Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_menu, err_menu = validation.check_length(msg["Menu-Id"], 128, "Menu-Id")
      if not ok_len_menu then
        return codec.error("INVALID_INPUT", err_menu, { field = "Menu-Id" })
      end
      if msg.Version then
        local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
        if not ok_len_ver then
          return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
        end
      end
      local version = msg.Version or state.active_versions[msg["Site-Id"]] or "active"
      local locale = pick_locale(msg["Site-Id"], msg.Locale)
      local cache_id = table.concat({ msg["Site-Id"], msg["Menu-Id"], version, locale }, "|")
      return with_cache("GetNavigation", cache_id, function()
        local key = ids.menu_key(msg["Site-Id"], msg["Menu-Id"], version, locale)
        local fallback = ids.menu_key(msg["Site-Id"], msg["Menu-Id"], version)
        local menu = state.menus[key] or state.menus[fallback]
        if not menu then
          return false,
            codec.error(
              "NOT_FOUND",
              "Navigation not found",
              { menuId = msg["Menu-Id"], version = version }
            )
        end
        if menu.items then
          for _, item in ipairs(menu.items) do
            if item.image then
              item.image.loading = item.image.loading or "lazy"
              item.image.placeholder = item.image.placeholder or "blur"
            end
          end
        end
        return true,
          {
            siteId = msg["Site-Id"],
            menuId = msg["Menu-Id"],
            version = version,
            locale = locale,
            items = menu.items,
            warnings = menu.warnings,
          }
      end)
    end
    
    function handlers.PutDraft(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Page-Id", "Content" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Page-Id",
        "Content",
        "Locale",
        "Content-Type",
        "Actor-Role",
        "Schema-Version",
        "ExpectedVersion",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_page, err_page = validation.check_length(msg["Page-Id"], 128, "Page-Id")
      if not ok_len_page then
        return codec.error("INVALID_INPUT", err_page, { field = "Page-Id" })
      end
      local ok_type, err_type = validation.assert_type(msg.Content, "table", "Content")
      if not ok_type then
        return codec.error("INVALID_INPUT", err_type, { field = "Content" })
      end
      -- normalize content against schema expectations
      if not msg.Content.id then
        msg.Content.id = msg["Page-Id"]
      end
      if not msg.Content.blocks then
        msg.Content.blocks = {}
      end
      local content_type = msg["Content-Type"] or "page"
      if
        state.content_types[msg["Site-Id"]] and not state.content_types[msg["Site-Id"]][content_type]
      then
        return codec.error("INVALID_INPUT", "Unknown content type", { contentType = content_type })
      end
      -- enforce lazy/blur on block images by default
      if msg.Content.blocks then
        for _, block in ipairs(msg.Content.blocks) do
          if type(block) == "table" and block.image and type(block.image) == "table" then
            block.image.loading = block.image.loading or "lazy"
            block.image.placeholder = block.image.placeholder or "blur"
          end
        end
      end
      local content_len = validation.estimate_json_length(msg.Content)
      local ok_size, err_size = validation.check_size(content_len, MAX_CONTENT_BYTES, "Content")
      if not ok_size then
        return codec.error("INVALID_INPUT", err_size, { field = "Content" })
      end
      local ok_schema, schema_err
      if content_type == "page" then
        ok_schema, schema_err = schema.validate("page", msg.Content)
      else
        local custom_schema = state.content_types[msg["Site-Id"]]
          and state.content_types[msg["Site-Id"]][content_type]
        ok_schema, schema_err = schema.validate_custom(custom_schema, msg.Content)
      end
      if not ok_schema then
        return codec.error("INVALID_INPUT", "Content failed schema", { errors = schema_err })
      end
      local ok_a11y, a11y_warnings = a11y.validate_page(msg.Content)
      if not ok_a11y and os.getenv "A11Y_STRICT" == "1" then
        return codec.error(
          "INVALID_INPUT",
          "Accessibility validation failed",
          { warnings = a11y_warnings }
        )
      end
      local locale = pick_locale(msg["Site-Id"], msg.Locale)
      local key = ids.page_key(msg["Site-Id"], msg["Page-Id"], "draft", locale)
      local previous = state.drafts[key]
      local conflicts = {}
      local block_conflicts = {}
      if previous and previous.content then
        local changed_fields = {}
        for k, v in pairs(msg.Content) do
          if previous.content[k] ~= v then
            table.insert(changed_fields, k)
          end
        end
        previous.versions = previous.versions or {}
        -- block-level conflict detection by id
        local prev_blocks = {}
        if previous.content.blocks then
          for _, b in ipairs(previous.content.blocks) do
            if type(b) == "table" and b.id then
              prev_blocks[b.id] = b
            end
          end
        end
        if msg.Merge == true and type(previous.content) == "table" then
          for k, v in pairs(msg.Content) do
            if type(v) == "table" and type(previous.content[k]) == "table" then
              for subk, subv in pairs(v) do
                previous.content[k][subk] = subv
              end
              msg.Content[k] = previous.content[k]
            elseif previous.content[k] ~= v and previous.content[k] ~= nil then
              conflicts[k] = { incoming = v, existing = previous.content[k] }
            end
          end
        end
        if msg.Content.blocks then
          for _, b in ipairs(msg.Content.blocks) do
            if type(b) == "table" and b.id and prev_blocks[b.id] and prev_blocks[b.id] ~= b then
              block_conflicts[b.id] = { incoming = b, existing = prev_blocks[b.id] }
            end
          end
        end
        for _, field in ipairs(changed_fields) do
          previous.versions[field] = (previous.versions[field] or 0) + 1
        end
        state.draft_audit[key] = state.draft_audit[key] or {}
        table.insert(state.draft_audit[key], {
          ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
          actor = msg.Subject or msg["Actor-Role"],
          fields = changed_fields,
          conflicts = conflicts,
          versions = previous.versions,
          block_conflicts = block_conflicts,
        })
      end
      state.drafts[key] = {
        content = msg.Content,
        updatedAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
        locale = locale,
        status = "draft",
        publishAt = msg.PublishAt,
        expireAt = msg.ExpireAt,
        contentType = content_type,
      }
      cache_purge_site(msg["Site-Id"])
      return codec.ok {
        draftId = key,
        warnings = a11y_warnings,
        locale = locale,
        contentType = content_type,
        conflicts = conflicts,
      }
    end
    
    function handlers.AddDraftComment(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id", "Author", "Body" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Draft-Id",
        "Author",
        "Body",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      state.draft_comments[msg["Draft-Id"]] = state.draft_comments[msg["Draft-Id"]] or {}
      table.insert(state.draft_comments[msg["Draft-Id"]], {
        author = msg.Author,
        body = msg.Body,
        ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
      })
      return codec.ok { draftId = msg["Draft-Id"], count = #state.draft_comments[msg["Draft-Id"]] }
    end
    
    function handlers.UpsertRoute(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Path", "Page-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Path",
        "Page-Id",
        "Layout-Id",
        "Type",
        "Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_path, err_path = validation.check_length(msg.Path, 2048, "Path")
      if not ok_len_path then
        return codec.error("INVALID_INPUT", err_path, { field = "Path" })
      end
      local ok_len_page, err_page = validation.check_length(msg["Page-Id"], 128, "Page-Id")
      if not ok_len_page then
        return codec.error("INVALID_INPUT", err_page, { field = "Page-Id" })
      end
      if msg["Layout-Id"] then
        local ok_len_layout, err_layout = validation.check_length(msg["Layout-Id"], 128, "Layout-Id")
        if not ok_len_layout then
          return codec.error("INVALID_INPUT", err_layout, { field = "Layout-Id" })
        end
      end
      if msg.Type then
        local ok_len_type, err_type = validation.check_length(msg.Type, 64, "Type")
        if not ok_len_type then
          return codec.error("INVALID_INPUT", err_type, { field = "Type" })
        end
      end
      local locale = pick_locale(msg["Site-Id"], msg.Locale)
      local key = ids.route_key(msg["Site-Id"], msg.Path, locale)
      state.routes[key] = {
        pageId = msg["Page-Id"],
        layoutId = msg["Layout-Id"],
        type = msg.Type or "page",
        locale = locale,
      }
      cache_purge_site(msg["Site-Id"])
      return codec.ok { path = msg.Path, pageId = msg["Page-Id"], locale = locale }
    end
    
    function handlers.UpsertLayout(msg)
      local ok, missing = validation.require_fields(msg, { "Layout-Id", "Version", "Components" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Layout-Id",
        "Version",
        "Components",
        "Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_layout, err_layout = validation.check_length(msg["Layout-Id"], 128, "Layout-Id")
      if not ok_len_layout then
        return codec.error("INVALID_INPUT", err_layout, { field = "Layout-Id" })
      end
      local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
      if not ok_len_ver then
        return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
      end
      local ok_type, err_type = validation.assert_type(msg.Components, "table", "Components")
      if not ok_type then
        return codec.error("INVALID_INPUT", err_type, { field = "Components" })
      end
      local ok_layout, layout_warnings = layout_components.validate(msg.Components)
      if not ok_layout and os.getenv "LAYOUT_STRICT" == "1" then
        return codec.error("INVALID_INPUT", "Layout components invalid", { warnings = layout_warnings })
      end
      local locale = msg.Locale and msg.Locale:lower() or nil
      local key = ids.layout_key(msg["Layout-Id"], msg.Version, locale)
      state.layouts[key] = { content = msg.Components, locale = locale, warnings = layout_warnings }
      audit.record(
        "site",
        "UpsertLayout",
        msg,
        nil,
        { layoutId = msg["Layout-Id"], version = msg.Version, locale = locale }
      )
      cache_purge_match(msg["Layout-Id"])
      return codec.ok {
        layoutId = msg["Layout-Id"],
        version = msg.Version,
        locale = locale,
        warnings = layout_warnings,
      }
    end
    
    function handlers.RegisterAsset(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Asset-Id", "Url" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Asset-Id",
        "Url",
        "Type",
        "Formats",
        "Sizes",
        "Base-Url",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_id, err_id = validation.check_length(msg["Asset-Id"], 256, "Asset-Id")
      if not ok_len_id then
        return codec.error("INVALID_INPUT", err_id, { field = "Asset-Id" })
      end
      local ok_len_url, err_url = validation.check_length(msg.Url, 2048, "Url")
      if not ok_len_url then
        return codec.error("INVALID_INPUT", err_url, { field = "Url" })
      end
      local typ = msg.Type or "image"
      if typ ~= "image" and typ ~= "video" then
        return codec.error("INVALID_INPUT", "Type must be image|video", { field = "Type" })
      end
      state.assets[msg["Site-Id"]] = state.assets[msg["Site-Id"]] or {}
      local meta = { type = typ, url = msg.Url }
      if typ == "image" then
        local manifest = assets.build_image_variants(msg.Url, {
          sizes = msg.Sizes,
          formats = msg.Formats,
          base_url = msg["Base-Url"],
        })
        meta.variants = manifest.variants
        meta.srcset = manifest.srcset
        meta.formats = manifest.formats
        meta.sizes = manifest.sizes
        meta.src = manifest.src
        meta.loading = manifest.loading
        meta.placeholder = manifest.placeholder
      end
      state.assets[msg["Site-Id"]][msg["Asset-Id"]] = meta
      audit.record(
        "site",
        "RegisterAsset",
        msg,
        nil,
        { siteId = msg["Site-Id"], assetId = msg["Asset-Id"], type = typ }
      )
      cache_purge_site(msg["Site-Id"])
      return codec.ok { siteId = msg["Site-Id"], assetId = msg["Asset-Id"], asset = meta }
    end
    
    function handlers.GetAsset(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Asset-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Asset-Id", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local assets_for_site = state.assets[msg["Site-Id"]] or {}
      local asset = assets_for_site[msg["Asset-Id"]]
      if not asset then
        return codec.error("NOT_FOUND", "Asset not found", { assetId = msg["Asset-Id"] })
      end
      return codec.ok { siteId = msg["Site-Id"], assetId = msg["Asset-Id"], asset = asset }
    end
    
    function handlers.SetLocales(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Locales" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Locales",
        "Default-Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local supported, default_locale, err_loc = validate_locales(msg)
      if not supported then
        return codec.error("INVALID_INPUT", err_loc, { field = "Locales" })
      end
      state.locales[msg["Site-Id"]] = { supported = supported, default = default_locale }
      audit.record(
        "site",
        "SetLocales",
        msg,
        nil,
        { siteId = msg["Site-Id"], default = default_locale }
      )
      cache_purge_site(msg["Site-Id"])
      return codec.ok { siteId = msg["Site-Id"], defaultLocale = default_locale, locales = supported }
    end
    
    -- Simple sitemap/robots generation from in-memory pages (scaffolding only)
    function handlers.GenerateSitemap(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Base-Url" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local started = os.clock()
      cache_purge_site(msg["Site-Id"]) -- safety noop for sitemap cache consumers
      local base = msg["Base-Url"]:gsub("/+$", "")
      local urls = {}
      local prefix = "page:" .. msg["Site-Id"] .. ":"
      for key, page in pairs(state.pages) do
        if key:sub(1, #prefix) == prefix and not page.archived then
          local parts = {}
          for part in key:gmatch "[^:]+" do
            table.insert(parts, part)
          end
          local page_id = parts[3]
          local loc = string.format("%s/%s", base, page_id)
          table.insert(urls, { loc = loc, lastmod = page.updatedAt or os.date "!%Y-%m-%d" })
        end
      end
      metrics.inc "ao_sitemap_export_total"
      metrics.gauge("ao_sitemap_export_duration_seconds", os.clock() - started)
      return codec.ok { siteId = msg["Site-Id"], urls = urls, count = #urls }
    end
    
    function handlers.GenerateRobots(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Base-Url" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      cache_purge_site(msg["Site-Id"])
      local lines = {
        "User-agent: *",
        "Allow: /",
        "Sitemap: " .. msg["Base-Url"]:gsub("/+$", "") .. "/sitemap.xml",
      }
      return codec.ok { siteId = msg["Site-Id"], robots = table.concat(lines, "\n") }
    end
    
    function handlers.PublishVersion(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Version" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Version",
        "ExpectedVersion",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
      if not ok_len_ver then
        return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
      end
      if msg.ExpectedVersion then
        local ok_len_exp, err_exp = validation.check_length(msg.ExpectedVersion, 128, "ExpectedVersion")
        if not ok_len_exp then
          return codec.error("INVALID_INPUT", err_exp, { field = "ExpectedVersion" })
        end
      end
      local site = msg["Site-Id"]
      local snapshots = {}
      local current = state.active_versions[site]
      if msg.ExpectedVersion and current and current ~= msg.ExpectedVersion then
        return codec.error(
          "VERSION_CONFLICT",
          "ExpectedVersion mismatch",
          { expected = msg.ExpectedVersion, current = current }
        )
      end
      -- promote drafts to versioned pages for this site and bundle snapshot (locale-aware)
      local prefix = "page:" .. site .. ":"
      for key, draft in pairs(state.drafts) do
        if key:sub(1, #prefix) == prefix then
          local parts = {}
          for part in key:gmatch "[^:]+" do
            table.insert(parts, part)
          end
          local page_id = parts[3]
          local locale = parts[5]
          local target_key = ids.page_key(site, page_id, msg.Version, locale)
          state.pages[target_key] =
            { content = draft.content, locale = locale, warnings = draft.warnings }
          table.insert(snapshots, { pageId = page_id, content = draft.content, locale = locale })
        end
      end
    
      local manifestTx
      local manifestHash
      if #snapshots > 0 then
        manifestTx, manifestHash =
          ar.put_snapshot { siteId = site, version = msg.Version, pages = snapshots }
        if not manifestTx then
          return codec.error("INVALID_INPUT", "Snapshot too large for Arweave manifest")
        end
      end
    
      state.active_versions[site] = msg.Version
      local resp = codec.ok {
        siteId = site,
        activeVersion = msg.Version,
        manifestTx = manifestTx,
        manifestHash = manifestHash,
        warnings = state.publish_log,
      }
      audit.record("site", "PublishVersion", msg, resp, { manifestTx = manifestTx })
      cache_purge_site(site)
      return resp
    end
    
    function handlers.ArchivePage(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Page-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Page-Id",
        "Version",
        "Locale",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_page, err_page = validation.check_length(msg["Page-Id"], 128, "Page-Id")
      if not ok_len_page then
        return codec.error("INVALID_INPUT", err_page, { field = "Page-Id" })
      end
      if msg.Version then
        local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
        if not ok_len_ver then
          return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
        end
      end
      local version = msg.Version or state.active_versions[msg["Site-Id"]] or "active"
      local locale = pick_locale(msg["Site-Id"], msg.Locale)
      local key = ids.page_key(msg["Site-Id"], msg["Page-Id"], version, locale)
      local fallback = ids.page_key(msg["Site-Id"], msg["Page-Id"], version)
      if state.pages[key] then
        state.pages[key].archived = true
      elseif state.pages[fallback] then
        state.pages[fallback].archived = true
      end
      cache_purge_site(msg["Site-Id"])
      return codec.ok { pageId = msg["Page-Id"], version = version, locale = locale, archived = true }
    end
    
    -- Authoring workflow -----------------------------------------------------
    local function assert_lock(draft_id, subject)
      local lock = state.draft_locks[draft_id]
      if not lock then
        return true
      end
      local ttl = lock.ttl or 900
      if os.time() - (lock.ts or 0) > ttl then
        state.draft_locks[draft_id] = nil
        return true
      end
      if lock.subject == subject then
        lock.ts = os.time()
        return true
      end
      return false, "LOCKED_BY_OTHER"
    end
    
    function handlers.LockDraft(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id", "Subject" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local allowed, reason = assert_lock(msg["Draft-Id"], msg.Subject)
      if not allowed then
        return codec.error("CONFLICT", reason)
      end
      state.draft_locks[msg["Draft-Id"]] = { subject = msg.Subject, ts = os.time(), ttl = 900 }
      return codec.ok { draftId = msg["Draft-Id"], subject = msg.Subject }
    end
    
    function handlers.UnlockDraft(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id", "Subject" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local lock = state.draft_locks[msg["Draft-Id"]]
      if lock and lock.subject ~= msg.Subject then
        return codec.error("FORBIDDEN", "Only lock owner can unlock")
      end
      state.draft_locks[msg["Draft-Id"]] = nil
      return codec.ok { draftId = msg["Draft-Id"], unlocked = true }
    end
    
    function handlers.ForceUnlockDraft(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local reason_map = {
        stale_lock = "Lock expired or owner offline",
        user_request = "User requested override",
        admin_override = "Administrator override",
        migration = "System migration",
      }
      state.draft_locks[msg["Draft-Id"]] = nil
      audit.record("site", "ForceUnlockDraft", msg, nil, {
        draftId = msg["Draft-Id"],
        reason = msg.Reason or "unspecified",
        code = msg["Reason-Code"],
        resolvedReason = reason_map[msg["Reason-Code"]] or msg.Reason,
      })
      state.draft_audit[msg["Draft-Id"]] = state.draft_audit[msg["Draft-Id"]] or {}
      table.insert(state.draft_audit[msg["Draft-Id"]], {
        ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
        actor = msg.Subject or msg["Actor-Role"],
        fields = { "lock" },
        action = "force_unlock",
        reason = msg.Reason,
        code = msg["Reason-Code"],
        resolvedReason = reason_map[msg["Reason-Code"]] or msg.Reason,
      })
      return codec.ok {
        draftId = msg["Draft-Id"],
        unlocked = true,
        forced = true,
        reason = msg.Reason,
        resolvedReason = reason_map[msg["Reason-Code"]] or msg.Reason,
        code = msg["Reason-Code"],
      }
    end
    
    function handlers.RenewDraftLock(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id", "Subject" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local lock = state.draft_locks[msg["Draft-Id"]]
      if not lock or lock.subject ~= msg.Subject then
        return codec.error("FORBIDDEN", "Lock not held by subject")
      end
      lock.ts = os.time()
      return codec.ok { draftId = msg["Draft-Id"], renewed = true }
    end
    
    function handlers.RequestPublish(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id", "Requested-By" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local draft = state.drafts[msg["Draft-Id"]]
      if not draft then
        return codec.error("NOT_FOUND", "Draft not found")
      end
      draft.status = "in_review"
      draft.requestedBy = msg["Requested-By"]
      draft.requestedAt = os.date "!%Y-%m-%dT%H:%M:%SZ"
      return codec.ok { draftId = msg["Draft-Id"], status = draft.status }
    end
    
    function handlers.ApprovePublish(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id", "Approved-By" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local draft = state.drafts[msg["Draft-Id"]]
      if not draft then
        return codec.error("NOT_FOUND", "Draft not found")
      end
      draft.status = "approved"
      draft.approvedBy = msg["Approved-By"]
      draft.approvedAt = os.date "!%Y-%m-%dT%H:%M:%SZ"
      return codec.ok { draftId = msg["Draft-Id"], status = draft.status }
    end
    
    function handlers.SchedulePublish(msg)
      local ok, missing =
        validation.require_fields(msg, { "Site-Id", "Page-Id", "Version", "Publish-At" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local locale = pick_locale(msg["Site-Id"], msg.Locale)
      state.publish_schedules[msg["Site-Id"]] = state.publish_schedules[msg["Site-Id"]] or {}
      table.insert(state.publish_schedules[msg["Site-Id"]], {
        pageId = msg["Page-Id"],
        version = msg.Version,
        locale = locale,
        publishAt = msg["Publish-At"],
        expireAt = msg["Expire-At"],
        status = "pending",
        retryCount = 0,
        lastError = nil,
      })
      return codec.ok { siteId = msg["Site-Id"], count = #state.publish_schedules[msg["Site-Id"]] }
    end
    
    local function iso_to_ts(iso)
      if not iso or iso == "" then
        return nil
      end
      local year, mon, day, hour, min, sec =
        iso:match "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
      if not year then
        return nil
      end
      return os.time {
        year = tonumber(year),
        month = tonumber(mon),
        day = tonumber(day),
        hour = tonumber(hour),
        min = tonumber(min),
        sec = tonumber(sec),
        isdst = false,
      }
    end
    
    function handlers.RunPublishScheduler(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
    
      local now_ts = os.time()
      local sites = {}
      if msg["Site-Id"] then
        sites = { msg["Site-Id"] }
      else
        for site_id in pairs(state.publish_schedules) do
          table.insert(sites, site_id)
        end
      end
    
      local published = {}
      local expired = {}
    
      for _, site_id in ipairs(sites) do
        local pending = {}
        for _, entry in ipairs(state.publish_schedules[site_id] or {}) do
          local publish_ts = iso_to_ts(entry.publishAt)
          local expire_ts = iso_to_ts(entry.expireAt)
          local should_publish = publish_ts and publish_ts <= now_ts
          local should_expire = expire_ts and expire_ts <= now_ts
    
          if entry.status == "failed" then
            table.insert(pending, entry)
            break
          end
    
          if should_publish then
            local draft_key = ids.page_key(site_id, entry.pageId, "draft", entry.locale)
            local draft_fallback = ids.page_key(site_id, entry.pageId, "draft")
            local draft = state.drafts[draft_key] or state.drafts[draft_fallback]
            if draft then
              local target_key = ids.page_key(site_id, entry.pageId, entry.version, entry.locale)
              state.pages[target_key] = {
                content = draft.content,
                locale = entry.locale,
                publishedAt = entry.publishAt,
              }
              draft.status = "published"
              state.active_versions[site_id] = entry.version
              audit.record("site", "RunPublishScheduler", msg, nil, {
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
                action = "publish",
              })
              table.insert(published, {
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
              })
              table.insert(state.publish_log, {
                ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
                action = "publish",
                status = entry.status,
                retryCount = entry.retryCount,
                lastError = entry.lastError,
              })
              entry.status = "published"
              entry.lastError = nil
            else
              table.insert(pending, entry) -- no draft yet; keep waiting
              table.insert(state.publish_log, {
                ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
                action = "missing_draft",
                status = entry.status,
                retryCount = entry.retryCount,
                lastError = entry.lastError,
              })
              entry.retryCount = (entry.retryCount or 0) + 1
              entry.lastError = "draft_missing"
              if entry.retryCount >= MAX_PUBLISH_RETRY then
                entry.status = "failed"
                audit.record("site", "RunPublishScheduler", msg, nil, {
                  siteId = site_id,
                  pageId = entry.pageId,
                  version = entry.version,
                  locale = entry.locale,
                  action = "failed_retry",
                  retryCount = entry.retryCount,
                  lastError = entry.lastError,
                })
                publish_alert(entry, "publish_failed_max_retry")
                table.insert(state.publish_log, {
                  ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
                  siteId = site_id,
                  pageId = entry.pageId,
                  version = entry.version,
                  locale = entry.locale,
                  action = "failed_retry",
                  retryCount = entry.retryCount,
                  lastError = entry.lastError,
                  status = entry.status,
                })
              end
            end
          end
    
          if should_expire then
            local page_key = ids.page_key(site_id, entry.pageId, entry.version, entry.locale)
            local page = state.pages[page_key]
            if page then
              page.archived = true
              audit.record("site", "RunPublishScheduler", msg, nil, {
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
                action = "expire",
              })
              table.insert(expired, {
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
              })
              table.insert(state.publish_log, {
                ts = os.date "!%Y-%m-%dT%H:%M:%SZ",
                siteId = site_id,
                pageId = entry.pageId,
                version = entry.version,
                locale = entry.locale,
                action = "expire",
              })
            end
          end
    
          if (not should_publish) and not should_expire then
            table.insert(pending, entry)
          end
        end
        state.publish_schedules[site_id] = pending
      end
    
      -- prune publish log to limit
      if #state.publish_log > PUBLISH_LOG_LIMIT then
        local drop = #state.publish_log - PUBLISH_LOG_LIMIT
        for _ = 1, drop do
          table.remove(state.publish_log, 1)
        end
      end
    
      return codec.ok {
        published = published,
        expired = expired,
        remaining = state.publish_schedules,
        logSize = #state.publish_log,
        statuses = state.publish_schedules,
      }
    end
    
    function handlers.GetPublishLog(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Limit",
        "Offset",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit or 100) or 100
      local offset = tonumber(msg.Offset or 0) or 0
      local items = {}
      local list = state.publish_log
      -- pagination is newest-last; offset from end
      local start = math.max(1, #list - offset - limit + 1)
      local last = math.max(start, #list - offset)
      for i = start, last do
        local entry = list[i]
        if not msg["Site-Id"] or (entry and entry.siteId == msg["Site-Id"]) then
          table.insert(items, entry)
        end
      end
      local total_site = 0
      if msg["Site-Id"] then
        for _, e in ipairs(list) do
          if e.siteId == msg["Site-Id"] then
            total_site = total_site + 1
          end
        end
      else
        total_site = #list
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        items = items,
        total = total_site,
        offset = offset,
        limit = limit,
      }
    end
    
    function handlers.ExportPublishLog(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local data = {}
      for _, item in ipairs(state.publish_log) do
        if (not msg["Site-Id"]) or item.siteId == msg["Site-Id"] then
          table.insert(data, item)
        end
      end
      if #data > PUBLISH_LOG_LIMIT then
        local start = #data - PUBLISH_LOG_LIMIT + 1
        local trimmed = {}
        for i = start, #data do
          table.insert(trimmed, data[i])
        end
        data = trimmed
      end
      local path = os.getenv "SITE_PUBLISH_LOG_EXPORT"
      if path then
        local f = io.open(path, "a")
        if f then
          f:write(require("cjson").encode(data), "\n")
          f:close()
        end
      end
      return codec.ok { siteId = msg["Site-Id"], items = data, total = #data }
    end
    
    function handlers.GetPublishStatus(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Page-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local items = {}
      for _, entry in ipairs(state.publish_schedules[msg["Site-Id"]] or {}) do
        if (not msg["Page-Id"]) or entry.pageId == msg["Page-Id"] then
          table.insert(items, entry)
        end
      end
      return codec.ok { siteId = msg["Site-Id"], items = items, total = #items }
    end
    
    function handlers.GetDraftAudit(msg)
      local ok, missing = validation.require_fields(msg, { "Draft-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Draft-Id",
        "Limit",
        "Offset",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit or 50) or 50
      local offset = tonumber(msg.Offset or 0) or 0
      local audit_log = state.draft_audit[msg["Draft-Id"]] or {}
      local items = {}
      for i = math.max(1, #audit_log - limit - offset + 1), math.max(0, #audit_log - offset) do
        items[#items + 1] = audit_log[i]
      end
      return codec.ok { draftId = msg["Draft-Id"], items = items, total = #items, offset = offset }
    end
    
    function handlers.RegisterContentType(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Name", "Schema" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if type(msg.Schema) ~= "table" then
        return codec.error("INVALID_INPUT", "Schema must be object", { field = "Schema" })
      end
      state.content_types[msg["Site-Id"]] = state.content_types[msg["Site-Id"]] or {}
      state.content_types[msg["Site-Id"]][msg.Name] = msg.Schema
      return codec.ok { siteId = msg["Site-Id"], name = msg.Name }
    end
    
    function handlers.ListContentTypes(msg)
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      return codec.ok { siteId = msg["Site-Id"], types = state.content_types[msg["Site-Id"]] or {} }
    end
    
    function handlers.SetPerfBudgets(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Budgets" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      state.perf_budgets[msg["Site-Id"]] = msg.Budgets
      return codec.ok { siteId = msg["Site-Id"], budgets = msg.Budgets }
    end
    
    function handlers.RecordWebVital(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Metric", "Value" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local budgets = state.perf_budgets[msg["Site-Id"]] or {}
      local metric = msg.Metric
      local value = msg.Value
      if metric == "LCP" and budgets.lcp_ms and value > budgets.lcp_ms then
        return codec.error(
          "PERF_BUDGET_EXCEEDED",
          "LCP over budget",
          { lcp = value, budget = budgets.lcp_ms }
        )
      end
      if metric == "CLS" and budgets.cls and value > budgets.cls then
        return codec.error(
          "PERF_BUDGET_EXCEEDED",
          "CLS over budget",
          { cls = value, budget = budgets.cls }
        )
      end
      if metric == "TBT" and budgets.tbt_ms and value > budgets.tbt_ms then
        return codec.error(
          "PERF_BUDGET_EXCEEDED",
          "TBT over budget",
          { tbt = value, budget = budgets.tbt_ms }
        )
      end
      state.perf_vitals[msg["Site-Id"]] = {
        metric = metric,
        value = value,
        ts = os.time(),
      }
      return codec.ok { siteId = msg["Site-Id"], metric = metric }
    end
    
    function handlers.RecordOrder(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Status" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Order-Id",
        "Status",
        "TotalAmount",
        "Currency",
        "VatRate",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      state.orders[msg["Site-Id"]] = state.orders[msg["Site-Id"]] or {}
      state.orders[msg["Site-Id"]][msg["Order-Id"]] = {
        status = msg.Status,
        totalAmount = msg.TotalAmount,
        currency = msg.Currency,
        vatRate = msg.VatRate,
        updatedAt = msg.Timestamp,
      }
      return codec.ok {
        siteId = msg["Site-Id"],
        orderId = msg["Order-Id"],
        status = msg.Status,
        totalAmount = msg.TotalAmount,
        currency = msg.Currency,
        vatRate = msg.VatRate,
      }
    end
    
    function handlers.GetOrder(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Order-Id", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site_orders = state.orders[msg["Site-Id"]] or {}
      local order = site_orders[msg["Order-Id"]]
      if not order then
        return codec.error("NOT_FOUND", "Order not found", { orderId = msg["Order-Id"] })
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        orderId = msg["Order-Id"],
        status = order.status,
        totalAmount = order.totalAmount,
        currency = order.currency,
        vatRate = order.vatRate,
        updatedAt = order.updatedAt,
        reason = order.reason,
      }
    end
    
    function handlers.ListOrders(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Status",
        "Page",
        "PageSize",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local page = tonumber(msg.Page or 1) or 1
      local page_size = tonumber(msg.PageSize or 20) or 20
      local site_orders = state.orders[msg["Site-Id"]] or {}
      local items = {}
      for oid, o in pairs(site_orders) do
        if not msg.Status or msg.Status == o.status then
          table.insert(items, {
            orderId = oid,
            status = o.status,
            totalAmount = o.totalAmount,
            currency = o.currency,
            vatRate = o.vatRate,
            updatedAt = o.updatedAt,
          })
        end
      end
      table.sort(items, function(a, b)
        return tostring(a.updatedAt or "") > tostring(b.updatedAt or "")
      end)
      local start = (page - 1) * page_size + 1
      local slice = {}
      for i = start, math.min(#items, start + page_size - 1) do
        table.insert(slice, items[i])
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        total = #items,
        page = page,
        pageSize = page_size,
        items = slice,
      }
    end
    
    local function route(msg)
      local ok, missing = validation.require_tags(msg, { "Action" })
      if not ok then
        return codec.missing_tags(missing)
      end
    
      local ok_sec, sec_err = auth.enforce(msg)
      if not ok_sec then
        return codec.error("FORBIDDEN", sec_err)
      end
    
      local seen = idem.check(msg["Request-Id"])
      if seen then
        return seen
      end
    
      local ok_action, err = validation.require_action(msg, allowed_actions)
      if not ok_action then
        if err == "unknown_action" then
          return codec.unknown_action(msg.Action)
        end
        return codec.error("MISSING_ACTION", "Action is required")
      end
    
      local ok_hmac, hmac_err = auth.verify_outbox_hmac(msg)
      if not ok_hmac then
        return codec.error("FORBIDDEN", hmac_err)
      end
    
      local ok_role, role_err = auth.require_role_for_action(msg, role_policy)
      if not ok_role then
        return codec.error("FORBIDDEN", role_err)
      end
    
      local handler = handlers[msg.Action]
      if not handler then
        return codec.unknown_action(msg.Action)
      end
    
      local resp = handler(msg)
      metrics.inc("site." .. msg.Action .. ".count")
      metrics.tick()
      idem.record(msg["Request-Id"], resp)
      persist.save("site_state", state)
      return resp
    end
    
    return {
      route = route,
      _state = state, -- exposed for tests
    }
    ]====], "ao.site.process")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.catalog.process"] = function()
      local loaded, err = load([====[-- Catalog process handlers: products, categories, listings.
    -- luacheck: ignore parse_header mark_webhook_seen record_shipment_event notify_customer purge_cache
    -- luacheck: ignore resize_and_store add_price_window parse_set is_eu is_vat_id_valid dimensional_weight
    -- luacheck: ignore push_low_stock deliver_stock_alert forget_subject pick_tax_rule
    
    local codec = require "ao.shared.codec"
    local validation = require "ao.shared.validation"
    local ids = require "ao.shared.ids"
    local auth = require "ao.shared.auth"
    local idem = require "ao.shared.idempotency"
    local audit = require "ao.shared.audit"
    local schema = require "ao.shared.schema"
    local metrics = require "ao.shared.metrics"
    local persist = require "ao.shared.persist"
    local json_ok, cjson = pcall(require, "cjson.safe")
    local RECENT_LIMIT = tonumber(os.getenv "CATALOG_RECENT_LIMIT" or "") or 20
    local SCA_FORCE = os.getenv "CATALOG_SCA_FORCE" == "1"
    local MAX_RATE_OPTIONS = tonumber(os.getenv "CATALOG_MAX_RATE_OPTIONS" or "") or 5
    local RISK_THRESHOLD = tonumber(os.getenv "CATALOG_MANUAL_REVIEW_THRESHOLD" or "") or 90
    local TELEMETRY_EXPORT_PATH = os.getenv "CATALOG_TELEMETRY_PATH"
    local TELEMETRY_KAFKA_PATH = os.getenv "CATALOG_TELEMETRY_KAFKA" -- mock sink file
    local TELEMETRY_S3_PATH = os.getenv "CATALOG_TELEMETRY_S3" -- mock sink file
    local INVOICE_EXPORT_PATH = os.getenv "CATALOG_INVOICE_PATH"
    local CARRIER_LABEL_BASE = os.getenv "CATALOG_CARRIER_LABEL_BASE" or "https://labels.example/"
    local CARRIER_TRACK_BASE = os.getenv "CATALOG_CARRIER_TRACK_BASE" or "https://track.example/"
    local CARRIER_API_URL = os.getenv "CATALOG_CARRIER_API_URL" -- optional external rate/label stub
    local CARRIER_API_TOKEN = os.getenv "CATALOG_CARRIER_API_TOKEN"
    local INVOICE_PDF_DIR = os.getenv "CATALOG_INVOICE_PDF_DIR"
    local INVOICE_NUMBER_WITH_YEAR = os.getenv "CATALOG_INVOICE_YEAR" ~= "0"
    local INVOICE_S3_BUCKET = os.getenv "CATALOG_INVOICE_S3_BUCKET"
    local HTTP_TIMEOUT = tonumber(os.getenv "CATALOG_HTTP_TIMEOUT" or "") or 5
    local HTTP_CONNECT_TIMEOUT = tonumber(os.getenv "CATALOG_HTTP_CONNECT_TIMEOUT" or "") or 2
    local S3_TIMEOUT = tonumber(os.getenv "CATALOG_S3_TIMEOUT" or "") or 10
    local S3_RETRIES = tonumber(os.getenv "CATALOG_S3_RETRIES" or "") or 2
    local EVENT_LOG_LIMIT = tonumber(os.getenv "CATALOG_EVENT_LOG_LIMIT" or "") or 5000
    local RATE_LIMIT_WINDOW = tonumber(os.getenv "CATALOG_RATE_LIMIT_WINDOW" or "") or 60
    local RATE_LIMIT_MAX = tonumber(os.getenv "CATALOG_RATE_LIMIT_MAX" or "") or 120
    local GA4_ENDPOINT = os.getenv "CATALOG_GA4_ENDPOINT"
    local GA4_API_SECRET = os.getenv "CATALOG_GA4_API_SECRET"
    local GA4_MEASUREMENT_ID = os.getenv "CATALOG_GA4_MEASUREMENT_ID"
    local PAYMENT_WEBHOOK_SECRET = os.getenv "CATALOG_PAYMENT_WEBHOOK_SECRET"
    local CARRIER_WEBHOOK_SECRET = os.getenv "CATALOG_CARRIER_WEBHOOK_SECRET"
    local RETURN_LABEL_BASE = os.getenv "CATALOG_RETURN_LABEL_BASE" or CARRIER_LABEL_BASE
    local CARRIER_LABEL_API_URL = os.getenv "CATALOG_CARRIER_LABEL_API_URL"
    local CARRIER_LABEL_API_KEY = os.getenv "CATALOG_CARRIER_LABEL_API_KEY"
    local JWT_HMAC_SECRET = os.getenv "CATALOG_JWT_SECRET" or os.getenv "JWT_SECRET"
    local INVOICE_SIGN_SECRET = os.getenv "CATALOG_INVOICE_SIGN_SECRET"
    local PDF_RENDER_CMD = os.getenv "CATALOG_PDF_RENDER_CMD" or "cat" -- expects: CMD input.html output.pdf
    local FEED_EXPORT_PATH = os.getenv "CATALOG_FEED_EXPORT_PATH"
    local MERCHANT_CENTER_PATH = os.getenv "CATALOG_MERCHANT_CENTER_PATH"
    local MERCHANT_CENTER_COUNTRY = os.getenv "CATALOG_MERCHANT_CENTER_COUNTRY" or "US"
    local MERCHANT_CENTER_CURRENCY = os.getenv "CATALOG_MERCHANT_CENTER_CURRENCY" or "USD"
    local STOCK_ALERT_WEBHOOK = os.getenv "CATALOG_STOCK_ALERT_WEBHOOK"
    local CDN_PURGE_CMD = os.getenv "CATALOG_CDN_PURGE_CMD" or os.getenv "CDN_PURGE_CMD"
    local RMA_WEBHOOK = os.getenv "CATALOG_RMA_WEBHOOK"
    local STRIPE_SECRET = os.getenv "CATALOG_STRIPE_SECRET"
    local STRIPE_WEBHOOK_SECRET = os.getenv "CATALOG_STRIPE_WEBHOOK_SECRET"
    local STRIPE_WEBHOOK_ID = os.getenv "CATALOG_STRIPE_WEBHOOK_ID"
    local STRIPE_VERIFY_EVENT = os.getenv "CATALOG_STRIPE_VERIFY_EVENT" == "1"
    local APPLE_PAY_MERCHANT_ID = os.getenv "CATALOG_APPLE_PAY_MERCHANT_ID" -- luacheck: ignore
    local GOOGLE_PAY_MERCHANT_ID = os.getenv "CATALOG_GOOGLE_PAY_MERCHANT_ID" -- luacheck: ignore
    local ADYEN_MERCHANT_ACCOUNT = os.getenv "CATALOG_ADYEN_MERCHANT_ACCOUNT" -- luacheck: ignore
    local PSP_MODE = os.getenv "CATALOG_PSP_MODE" or "sandbox" -- sandbox|live
    local PSP_ALLOW_STUB = os.getenv "CATALOG_PSP_ALLOW_STUB" ~= "0"
    local PSP_HOSTED_ONLY = os.getenv "CATALOG_PSP_HOSTED_ONLY" == "1" -- disallow server-side PSP flows
    local PAYPAL_WEBHOOK_ID = os.getenv "CATALOG_PAYPAL_WEBHOOK_ID"
    local PAYPAL_WEBHOOK_SECRET = os.getenv "CATALOG_PAYPAL_WEBHOOK_SECRET"
    local PAYPAL_CERT_HOST = os.getenv "CATALOG_PAYPAL_CERT_HOST" or "paypal.com"
    local PAYPAL_CERT_CACHE_SEC = tonumber(os.getenv "CATALOG_PAYPAL_CERT_CACHE_SEC" or "") or 3600
    local CARRIER_WEBHOOK_TOLERANCE = tonumber(os.getenv "CATALOG_CARRIER_WEBHOOK_TOLERANCE" or "")
      or 600
    local ADYEN_HMAC_KEY = os.getenv "CATALOG_ADYEN_HMAC_KEY"
    local CDN_SURROGATE_CMD = os.getenv "CATALOG_CDN_SURROGATE_CMD"
    -- optional, e.g. "curl -sS -X POST https://api.fastly.com/service/... -H 'Fastly-Key: ...' -H 'Surrogate-Key: %s'"
    local IMAGE_RESIZE_CMD = os.getenv "CATALOG_IMAGE_RESIZE_CMD" -- e.g. "vipsthumbnail %s --size %dx%d -o %s"
    local IMAGE_STORE_DIR = os.getenv "CATALOG_IMAGE_STORE_DIR"
    local IMAGE_FORMATS = os.getenv "CATALOG_IMAGE_FORMATS" or "webp,avif,jpg"
    local IMAGE_SIZES = os.getenv "CATALOG_IMAGE_SIZES" or "320x320,640x640,1280x1280"
    local IMAGE_S3_BUCKET = os.getenv "CATALOG_IMAGE_S3_BUCKET"
    local IMAGE_S3_PREFIX = os.getenv "CATALOG_IMAGE_S3_PREFIX" or ""
    local IMAGE_PUBLIC_BASE = os.getenv "CATALOG_IMAGE_PUBLIC_BASE"
    local US_NEXUS_STATES = os.getenv "CATALOG_US_NEXUS_STATES" or ""
    local RETENTION_DAYS = tonumber(os.getenv "CATALOG_RETENTION_DAYS" or "") or 30
    local SEARCH_SYNONYMS_PATH = os.getenv "CATALOG_SEARCH_SYNONYMS_PATH"
    local SEARCH_STOPWORDS_PATH = os.getenv "CATALOG_SEARCH_STOPWORDS_PATH"
    local CUSTOMER_WEBHOOK = os.getenv "CATALOG_CUSTOMER_WEBHOOK"
    local NOTIFY_RETRIES = tonumber(os.getenv "CATALOG_NOTIFY_RETRIES" or "") or 2
    local NOTIFY_BACKOFF_MS = tonumber(os.getenv "CATALOG_NOTIFY_BACKOFF_MS" or "") or 200
    local IMPORT_MAX_ROWS = tonumber(os.getenv "CATALOG_IMPORT_MAX_ROWS" or "") or 5000
    local THREE_DS_URL = os.getenv "CATALOG_3DS_URL" or "https://3ds.example.com/challenge/"
    local WEBHOOK_REPLAY_WINDOW = tonumber(os.getenv "CATALOG_WEBHOOK_REPLAY_WINDOW" or "") or 600
    local CHALLENGE_TTL = tonumber(os.getenv "CATALOG_3DS_TTL" or "") or 900
    local MERCHANT_COUNTRY = (os.getenv "CATALOG_MERCHANT_COUNTRY" or "US"):upper()
    local WORKER_FORGET_URL = os.getenv "WORKER_FORGET_URL"
    local WORKER_AUTH_TOKEN = os.getenv "WORKER_AUTH_TOKEN" or os.getenv "WORKER_FORGET_TOKEN"
    
    local openssl_ok, openssl = pcall(require, "openssl")
    local sodium_ok, sodium = pcall(require, "sodium")
    if not sodium_ok then
      sodium_ok, sodium = pcall(require, "luasodium")
    end
    
    -- forward declarations to satisfy luacheck
    local parse_header
    local mark_webhook_seen
    local record_shipment_event
    local notify_customer
    local purge_cache
    local resize_and_store
    local add_price_window
    local parse_set
    local is_eu
    local is_vat_id_valid
    local dimensional_weight
    local push_low_stock
    local deliver_stock_alert
    local forget_subject
    
    -- ensure purge_cache exists even if later definition is skipped
    if not purge_cache then
      function purge_cache(_) end
    end
    
    local handlers = {}
    local allowed_actions = {
      "GetProduct",
      "ListCategoryProducts",
      "SearchCatalog",
      "FacetSearch",
      "GetRecommendations",
      "GetOrder",
      "ListOrders",
      "ApplyOrderEvent",
      "UpsertProduct",
      "UpsertVariants",
      "UpsertCategory",
      "PublishCatalogVersion",
      "SetInventoryReservation",
      "SyncShipment",
      "SyncReturn",
      "ApplyShipmentEvent",
      "ApplyTrackingEvent",
      "GetShippingRates",
      "GetTaxRates",
      "ValidateAddress",
      "GetShipment",
      "SetPriceList",
      "AddPromo",
      "ApplyCoupon",
      "UpsertPriceList",
      "SetPriceList",
      "QuotePrice",
      "SetTaxRules",
      "SetShippingRules",
      "QuoteOrder",
      "StartCheckout",
      "CompleteCheckout",
      "SetInventory",
      "GetInventory",
      "TrackCatalogEvent",
      "ExportEvents",
      "RelatedProducts",
      "RecentlyViewed",
      "GetRecommendations",
      "CreatePaymentIntent",
      "CapturePayment",
      "RefundPayment",
      "SavePaymentToken",
      "AddStoreCredit",
      "ApplyStoreCredit",
      "SaveAddress",
      "ListAddresses",
      "SetConsents",
      "RequestReturn",
      "ApproveReturn",
      "RefundReturn",
      "CalculateTax",
      "RateShopCarriers",
      "ExportTelemetry",
      "CreateCompanyAccount",
      "AddCompanyUser",
      "CreatePurchaseOrder",
      "ApprovePurchaseOrder",
      "RejectPurchaseOrder",
      "CheckoutPurchaseOrder",
      "SetCompanyTerms",
      "CreateShippingLabel",
      "CreateInvoice",
      "GetInvoice",
      "ListInvoices",
      "Bestsellers",
      "TrendingProducts",
      "ExportEventLog",
      "StreamTelemetry",
      "HandlePaymentWebhook",
      "HandleCarrierWebhook",
      "UpdateReturnStatus",
      "CreateReturnLabel",
      "SetEdgeCachePolicy",
      "SetFeatureFlags",
      "CreateWebhook",
      "GetWebhook",
      "ListWebhooks",
      "DeleteWebhook",
      "SignPayload",
      "VerifySignature",
      "ExportCatalogFeed",
      "ExportSearchFeed",
      "ExportCategoryFeed",
      "DeleteProduct",
      "DeleteCategory",
      "PurgeCache",
      "ExportMerchantFeed",
      "SetStockPolicy",
      "ListLowStock",
      "GetCategory",
      "ListCategories",
      "DeliverLowStockAlerts",
      "ForgetSubject",
      "ListBackorders",
      "TokenizePaymentMethod",
      "HandlePaymentProviderWebhook",
      "CleanupRetention",
      "ExportRecommendations",
      "ListNotificationFailures",
      "ImportCatalogCSV",
      "BulkPriceUpdate",
      "Complete3DSChallenge",
    }
    
    local role_policy = {
      UpsertProduct = { "catalog-admin", "editor", "admin" },
      UpsertVariants = { "catalog-admin", "editor", "admin" },
      UpsertCategory = { "catalog-admin", "editor", "admin" },
      PublishCatalogVersion = { "publisher", "admin", "catalog-admin" },
      SetInventoryReservation = { "catalog-admin", "admin" },
      SyncShipment = { "catalog-admin", "admin" },
      SyncReturn = { "catalog-admin", "admin" },
      ApplyOrderEvent = { "admin", "catalog-admin" },
      ApplyShipmentEvent = { "admin", "catalog-admin", "support" },
      ApplyTrackingEvent = { "admin", "catalog-admin", "support" },
      GetShippingRates = { "support", "admin", "catalog-admin" },
      GetTaxRates = { "support", "admin", "catalog-admin" },
      ValidateAddress = { "support", "admin" },
      GetShipment = { "support", "admin" },
      SetPriceList = { "catalog-admin", "admin" },
      UpsertPriceList = { "catalog-admin", "admin" },
      AddPromo = { "catalog-admin", "admin" },
      ApplyCoupon = { "catalog-admin", "support", "admin", "viewer" },
      QuotePrice = { "catalog-admin", "support", "admin" },
      SetTaxRules = { "catalog-admin", "admin" },
      SetShippingRules = { "catalog-admin", "admin" },
      QuoteOrder = { "catalog-admin", "support", "admin" },
      StartCheckout = { "catalog-admin", "support", "admin" },
      CompleteCheckout = { "catalog-admin", "support", "admin" },
      SetInventory = { "catalog-admin", "admin" },
      GetInventory = { "catalog-admin", "support", "admin" },
      TrackCatalogEvent = { "catalog-admin", "support", "admin", "viewer" },
      ExportEvents = { "admin", "catalog-admin", "support" },
      RelatedProducts = { "catalog-admin", "support", "admin", "viewer" },
      RecentlyViewed = { "catalog-admin", "support", "admin", "viewer" },
      GetRecommendations = { "catalog-admin", "support", "admin", "viewer" },
      CreatePaymentIntent = { "catalog-admin", "support", "admin" },
      CapturePayment = { "catalog-admin", "support", "admin" },
      RefundPayment = { "catalog-admin", "support", "admin" },
      SavePaymentToken = { "catalog-admin", "support", "admin", "viewer" },
      AddStoreCredit = { "support", "catalog-admin", "admin" },
      ApplyStoreCredit = { "catalog-admin", "support", "admin", "viewer" },
      SaveAddress = { "catalog-admin", "support", "admin", "viewer" },
      ListAddresses = { "catalog-admin", "support", "admin", "viewer" },
      SetConsents = { "catalog-admin", "support", "admin", "viewer" },
      RequestReturn = { "support", "catalog-admin", "admin" },
      ApproveReturn = { "support", "catalog-admin", "admin" },
      RefundReturn = { "support", "catalog-admin", "admin" },
      UpdateReturnStatus = { "support", "catalog-admin", "admin" },
      CalculateTax = { "catalog-admin", "support", "admin" },
      RateShopCarriers = { "catalog-admin", "support", "admin" },
      ExportTelemetry = { "admin", "catalog-admin" },
      CreateCompanyAccount = { "catalog-admin", "admin" },
      AddCompanyUser = { "catalog-admin", "admin" },
      CreatePurchaseOrder = { "buyer", "approver", "catalog-admin", "admin" },
      ApprovePurchaseOrder = { "approver", "catalog-admin", "admin" },
      RejectPurchaseOrder = { "approver", "catalog-admin", "admin" },
      CheckoutPurchaseOrder = { "catalog-admin", "admin", "approver" },
      SetCompanyTerms = { "b2b-admin", "admin" },
      CreateShippingLabel = { "catalog-admin", "admin", "support" },
      CreateInvoice = { "catalog-admin", "admin", "support" },
      GetInvoice = { "support", "admin", "catalog-admin" },
      ListInvoices = { "support", "admin", "catalog-admin" },
      Bestsellers = { "catalog-admin", "support", "admin", "viewer" },
      TrendingProducts = { "catalog-admin", "support", "admin", "viewer" },
      ExportEventLog = { "admin", "catalog-admin" },
      StreamTelemetry = { "admin", "catalog-admin" },
      HandlePaymentWebhook = { "admin", "catalog-admin" },
      HandleCarrierWebhook = { "admin", "catalog-admin", "support" },
      CreateReturnLabel = { "support", "catalog-admin", "admin" },
      SetEdgeCachePolicy = { "catalog-admin", "admin" },
      SetFeatureFlags = { "catalog-admin", "admin" },
      CreateWebhook = { "admin", "catalog-admin" },
      GetWebhook = { "admin", "catalog-admin" },
      ListWebhooks = { "admin", "catalog-admin" },
      DeleteWebhook = { "admin", "catalog-admin" },
      SignPayload = { "admin", "catalog-admin" },
      VerifySignature = { "admin", "catalog-admin" },
      ExportCatalogFeed = { "catalog-admin", "support", "admin", "viewer" },
      ExportSearchFeed = { "catalog-admin", "support", "admin", "viewer" },
      ExportCategoryFeed = { "catalog-admin", "support", "admin", "viewer" },
      DeleteProduct = { "catalog-admin", "editor", "admin" },
      DeleteCategory = { "catalog-admin", "editor", "admin" },
      PurgeCache = { "catalog-admin", "admin", "support" },
      ExportMerchantFeed = { "catalog-admin", "support", "admin" },
      SetStockPolicy = { "catalog-admin", "admin" },
      ListLowStock = { "catalog-admin", "admin", "support" },
      GetCategory = { "catalog-admin", "support", "admin", "viewer" },
      ListCategories = { "catalog-admin", "support", "admin", "viewer" },
      DeliverLowStockAlerts = { "catalog-admin", "admin", "support" },
      ForgetSubject = { "admin", "catalog-admin", "support" },
      ListBackorders = { "catalog-admin", "admin", "support" },
      TokenizePaymentMethod = { "catalog-admin", "support", "admin" },
      HandlePaymentProviderWebhook = { "catalog-admin", "support", "admin" },
      CleanupRetention = { "admin", "catalog-admin" },
      ExportRecommendations = { "catalog-admin", "support", "admin", "viewer" },
      ListNotificationFailures = { "admin", "catalog-admin", "support" },
      ImportCatalogCSV = { "catalog-admin", "admin" },
      BulkPriceUpdate = { "catalog-admin", "admin" },
      Complete3DSChallenge = { "catalog-admin", "support", "admin" },
    }
    
    local state = persist.load("catalog_state", {
      products = {}, -- product:<site>:<sku> -> { payload }
      categories = {}, -- category:<site>:<id> -> { payload, products = {sku}}
      active_versions = {}, -- site -> version
      inventory = {}, -- siteId -> warehouse -> { sku -> qty }
      reservations = {}, -- orderId -> { siteId, items = { { sku, qty } }, released=false }
      orders = {}, -- orderId -> order record
      shipments = {}, -- shipmentId -> { status, tracking, carrier, eta, orderId }
      returns = {}, -- returnId -> { status, reason, orderId }
      assets = {}, -- siteId -> sku -> { original, variants = { {url, w, h, fmt} } }
      shipping_rates = {}, -- siteId -> list of rate rows
      tax_rates = {}, -- siteId -> list of tax rows
      price_lists = {}, -- siteId -> currency -> { sku -> price }
      price_windows = {}, -- siteId -> currency -> { { region, valid_from, valid_to, prices = {sku=price} } }
      promos = {}, -- code -> { type = "percent"|"amount", value, skus }
      coupons = {}, -- code -> { type, value, applies_to, free_shipping }
      variants = {}, -- siteId -> parentSku -> { variants = { { sku, attrs, price } } }
      tax_rules = {}, -- siteId -> list { country, region?, rate }
      shipping_rules = {}, -- siteId -> list { country, min_total, max_total, rate, carrier, service }
      checkouts = {}, -- checkoutId -> { siteId, items, address, quote, status }
      events = {}, -- siteId -> sku -> { views, add_to_cart, purchases }
      recent = {}, -- subject -> list of { siteId, sku } (most recent first, capped)
      payments = {}, -- paymentId -> { status, amount, currency, method, siteId, orderId, checkoutId, requiresAction }
      payment_tokens = {}, -- subject -> { { provider, token, last4, brand, exp, default=true? } }
      store_credit = {}, -- subject -> { balance, currency }
      address_book = {}, -- subject -> { entries = { ... } }
      consents = {}, -- subject -> map of consent flags
      telemetry = {}, -- buffered events for export
      companies = {}, -- companyId -> { name, users = { [userId] = role } }
      purchase_orders = {}, -- poId -> { siteId, companyId, items, totals, status, approvals = {} }
      company_terms = {}, -- companyId -> { credit_limit, net_terms, currency, balance }
      invoices = {}, -- invoiceId -> { orderId, siteId, total, currency, lines, issuedAt, status }
      invoice_seq = {}, -- siteId -> last number
      invoice_seq_year = {}, -- siteId -> year -> last number
      event_log = {}, -- siteId -> list of { ts, sku, event }
      webhooks = {}, -- siteId -> id -> { url, secret, events }
      deletions = {}, -- siteId -> list of { key, deletedAt }
      category_deletions = {}, -- siteId -> list of { key, deletedAt }
      stock_policies = {}, -- siteId -> sku -> { allow_backorder, preorder_at, low_stock_threshold }
      stock_alerts = {}, -- siteId -> list of { sku, total, threshold, ts }
      backorders = {}, -- siteId -> list of { sku, qty, preorder_at, eta_days, createdAt, source, ref }
      shipment_events = {}, -- shipmentId -> list of { ts, status, meta }
      rate_limits = {}, -- key -> { count, window_start }
      search_synonyms = {}, -- siteId -> map term -> {synonyms}
      search_stopwords = {}, -- siteId -> set of stopwords
      notification_failures = {}, -- siteId -> list of { type, target, payload, attempts, ts }
      payment_attempts = {}, -- paymentId -> list of events
      webhook_seen = {}, -- id -> ts for replay protection
      provider_events = {}, -- provider -> id -> ts
      stripe_idempotency = {}, -- idemKey -> { paymentId, status }
      paypal_certs = {}, -- url -> { pem, fetchedAt }
    })
    
    local function gen_id(prefix)
      return string.format("%s-%d-%04d", prefix, os.time(), math.random(0, 9999))
    end
    
    local function hex_encode(bytes)
      if not bytes then
        return nil
      end
      if openssl_ok and openssl.hex then
        return openssl.hex(bytes)
      end
      if sodium_ok then
        if sodium.to_hex then
          return sodium.to_hex(bytes)
        end
        if sodium.bin2hex then
          return sodium.bin2hex(bytes)
        end
      end
      return (bytes:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
      end))
    end
    
    local function hmac_sha256_hex(data, key)
      if not key or key == "" then
        return nil, "missing_key"
      end
      if openssl_ok and openssl.hmac then
        local raw = openssl.hmac.digest("sha256", data, key, true)
        return hex_encode(raw)
      end
      if sodium_ok and sodium.crypto_auth then
        local raw = sodium.crypto_auth(data, key)
        return hex_encode(raw)
      end
      return nil, "hmac_unavailable"
    end
    
    -- PSP adapter shim -------------------------------------------------------
    local function psp_call(provider, action, payload)
      -- Pluggable PSP adapters. Currently sandbox stubs; replace with real REST/SDK calls when keys are provided.
      -- Contract:
      --   create_intent -> ok, { providerPaymentId, clientSecret, requiresAction?, nextActionUrl? } or nil, err
      --   capture       -> ok, { status = "captured", providerCaptureId? } or nil, err
      --   refund        -> ok, { status = "refunded", refundedAt?, amount? } or nil, err
    
      local adapters = {}
    
      adapters.stripe = function(act, p)
        if not STRIPE_SECRET or STRIPE_SECRET == "" then
          return nil, "PSP_NOT_CONFIGURED"
        end
        if act == "create_intent" then
          return true,
            {
              providerPaymentId = "pi_" .. gen_id "stripe",
              clientSecret = "cs_" .. gen_id "stripe",
              requiresAction = p.require3ds == true,
              nextActionUrl = p.require3ds and (THREE_DS_URL .. "?pid=" .. p.id) or nil,
            }
        elseif act == "capture" then
          return true, { status = "captured", capturedAt = os.time() }
        elseif act == "refund" then
          return true, { status = "refunded", refundedAt = os.time(), amount = p.amount }
        end
        return nil, "UNSUPPORTED_ACTION"
      end
    
      adapters.adyen = function(act, p)
        if not ADYEN_HMAC_KEY or ADYEN_HMAC_KEY == "" then
          return nil, "PSP_NOT_CONFIGURED"
        end
        if act == "create_intent" then
          return true,
            {
              providerPaymentId = "adyen_" .. gen_id "adyen",
              clientSecret = "sec_" .. gen_id "adyen",
              requiresAction = false,
            }
        elseif act == "capture" then
          return true, { status = "captured", capturedAt = os.time() }
        elseif act == "refund" then
          return true, { status = "refunded", refundedAt = os.time(), amount = p.amount }
        end
        return nil, "UNSUPPORTED_ACTION"
      end
    
      adapters.paypal = function(act, p)
        if not PAYPAL_WEBHOOK_ID or not PAYPAL_WEBHOOK_SECRET then
          return nil, "PSP_NOT_CONFIGURED"
        end
        if act == "create_intent" then
          return true,
            {
              providerPaymentId = "pp_" .. gen_id "pp",
              clientSecret = "sec_" .. gen_id "pp",
              requiresAction = false,
            }
        elseif act == "capture" then
          return true, { status = "captured", capturedAt = os.time() }
        elseif act == "refund" then
          return true, { status = "refunded", refundedAt = os.time(), amount = p.amount }
        end
        return nil, "UNSUPPORTED_ACTION"
      end
    
      adapters.default = function(act, p)
        if not PSP_ALLOW_STUB then
          return nil, "PSP_NOT_CONFIGURED"
        end
        if act == "create_intent" then
          return true,
            {
              providerPaymentId = "int_" .. gen_id "psp",
              clientSecret = "sec_" .. gen_id "psp",
              requiresAction = p.require3ds == true,
              nextActionUrl = p.require3ds and (THREE_DS_URL .. "?pid=" .. p.id) or nil,
            }
        elseif act == "capture" then
          return true, { status = "captured", capturedAt = os.time() }
        elseif act == "refund" then
          return true, { status = "refunded", refundedAt = os.time(), amount = p.amount }
        end
        return nil, "UNSUPPORTED_ACTION"
      end
    
      local adapter = adapters[provider] or adapters.default
      return adapter(action, payload)
    end
    
    local function mark_event_seen(provider, event_id, ts)
      if not provider or not event_id then
        return true
      end
      ts = ts or os.time()
      state.provider_events[provider] = state.provider_events[provider] or {}
      local last = state.provider_events[provider][event_id]
      if last and (ts - last) <= WEBHOOK_REPLAY_WINDOW then
        return false, "event_replayed"
      end
      state.provider_events[provider][event_id] = ts
      return true
    end
    
    local function stripe_fetch_event(event_id)
      if not STRIPE_SECRET or STRIPE_SECRET == "" or not event_id then
        return nil, "missing_secret"
      end
      local url = string.format("https://api.stripe.com/v1/events/%s", event_id)
      local cmd = string.format(
        "curl -sS --max-time %d --connect-timeout %d -u '%s:' %s",
        HTTP_TIMEOUT,
        HTTP_CONNECT_TIMEOUT,
        STRIPE_SECRET,
        url
      )
      local reader = io.popen(cmd, "r")
      if not reader then
        return nil, "curl_failed"
      end
      local body = reader:read "*a"
      local ok_close = reader:close()
      if not ok_close then
        return nil, "curl_exit"
      end
      if not json_ok then
        return body
      end
      local ok_dec, obj = pcall(cjson.decode, body)
      if ok_dec then
        return obj
      end
      return nil, "decode_failed"
    end
    
    local function hostname_from_url(url)
      if not url or url == "" then
        return nil
      end
      return url:match "^https?://([^/]+)"
    end
    
    local function fetch_paypal_cert(cert_url)
      if not cert_url or cert_url == "" then
        return nil, "no_cert_url"
      end
      local cached = state.paypal_certs[cert_url]
      if cached and (os.time() - cached.fetchedAt) < PAYPAL_CERT_CACHE_SEC then
        return cached.pem
      end
      local host = hostname_from_url(cert_url)
      if not host or not host:match(PAYPAL_CERT_HOST:gsub("%.", "%%.") .. "$") then
        return nil, "cert_host_blocked"
      end
      local cmd = string.format(
        "curl -sS --max-time %d --connect-timeout %d '%s'",
        HTTP_TIMEOUT,
        HTTP_CONNECT_TIMEOUT,
        cert_url
      )
      local reader = io.popen(cmd, "r")
      if not reader then
        return nil, "curl_failed"
      end
      local pem = reader:read "*a"
      local ok_close = reader:close()
      if not ok_close or not pem or pem == "" then
        return nil, "curl_exit"
      end
      state.paypal_certs[cert_url] = { pem = pem, fetchedAt = os.time() }
      return pem
    end
    
    local function verify_paypal_cert_signature(signed, signature_b64, cert_pem)
      if not signature_b64 or signature_b64 == "" then
        return false, "missing_signature"
      end
      local tmp_sig = os.tmpname()
      local tmp_cert = os.tmpname()
      local tmp_data = os.tmpname()
      local fdata = io.open(tmp_data, "w")
      if not fdata then
        return false, "tmp_data_failed"
      end
      fdata:write(signed)
      fdata:close()
      local tmp_b64 = os.tmpname()
      local fb = io.open(tmp_b64, "w")
      if not fb then
        os.remove(tmp_data)
        return false, "tmp_b64_failed"
      end
      fb:write(signature_b64)
      fb:close()
      local dec_rc = os.execute(string.format("base64 -d %s > %s", tmp_b64, tmp_sig))
      os.remove(tmp_b64)
      if dec_rc ~= true and dec_rc ~= 0 then
        os.remove(tmp_data)
        os.remove(tmp_sig)
        return false, "base64_decode_failed"
      end
      local fcert = io.open(tmp_cert, "w")
      if not fcert then
        os.remove(tmp_data)
        if tmp_sig then
          os.remove(tmp_sig)
        end
        return false, "tmp_cert_failed"
      end
      fcert:write(cert_pem)
      fcert:close()
      local cmd =
        string.format("openssl dgst -sha256 -verify %s -signature %s %s", tmp_cert, tmp_sig, tmp_data)
      local rc = os.execute(cmd)
      os.remove(tmp_data)
      if tmp_sig then
        os.remove(tmp_sig)
      end
      os.remove(tmp_cert)
      return rc == true or rc == 0, rc
    end
    
    local function cache_stripe_idempotency(msg, result)
      local idem_key = msg.IdempotencyKey or parse_header(msg.Headers, "Idempotency-Key")
      if idem_key and idem_key ~= "" then
        state.stripe_idempotency[idem_key] = result
      end
    end
    
    local function check_stripe_idempotency(msg)
      local idem_key = msg.IdempotencyKey or parse_header(msg.Headers, "Idempotency-Key")
      if idem_key and state.stripe_idempotency[idem_key] then
        return state.stripe_idempotency[idem_key]
      end
    end
    
    local function validate_payment_event(ev, pay)
      if
        ev.currency
        and pay.currency
        and tostring(ev.currency):upper() ~= tostring(pay.currency):upper()
      then
        return false, "currency_mismatch"
      end
      if ev.amount and pay.amount and ev.amount > (pay.amount + 0.01) then
        return false, "amount_exceeds"
      end
      if ev.type == "refund_succeeded" or ev.refundAmount then
        local refund_amt = ev.amount or ev.refundAmount or pay.refundAmount or 0
        if refund_amt > pay.amount then
          return false, "refund_gt_payment"
        end
      end
      if ev.orderId and pay.orderId and ev.orderId ~= pay.orderId then
        return false, "order_mismatch"
      end
      return true
    end
    
    local MAX_PAYLOAD_BYTES = tonumber(os.getenv "CATALOG_MAX_PAYLOAD_BYTES" or "") or (64 * 1024)
    local SHIPPING_RATES_PATH = os.getenv "AO_SHIPPING_RATES_PATH"
    local TAX_RATES_PATH = os.getenv "AO_TAX_RATES_PATH"
    
    local function load_ndjson(path)
      if not path or path == "" or not json_ok then
        return {}
      end
      local f = io.open(path, "r")
      if not f then
        return {}
      end
      local out = {}
      for line in f:lines() do
        local ok, obj = pcall(cjson.decode, line)
        if ok and obj then
          table.insert(out, obj)
        end
      end
      f:close()
      return out
    end
    
    local function load_rates()
      local ship = load_ndjson(SHIPPING_RATES_PATH)
      for _, r in ipairs(ship) do
        if r.siteId then
          state.shipping_rates[r.siteId] = state.shipping_rates[r.siteId] or {}
          table.insert(state.shipping_rates[r.siteId], r)
        end
      end
      local tax = load_ndjson(TAX_RATES_PATH)
      for _, t in ipairs(tax) do
        if t.siteId then
          state.tax_rates[t.siteId] = state.tax_rates[t.siteId] or {}
          table.insert(state.tax_rates[t.siteId], t)
        end
      end
    end
    
    local function load_synonyms()
      if not SEARCH_SYNONYMS_PATH or SEARCH_SYNONYMS_PATH == "" or not json_ok then
        return
      end
      local f = io.open(SEARCH_SYNONYMS_PATH, "r")
      if not f then
        return
      end
      local ok, data = pcall(cjson.decode, f:read "*a")
      f:close()
      if not ok or type(data) ~= "table" then
        return
      end
      -- expected format: { siteId = "...", synonyms = { { term = "tv", words = {"television","oled"} }, ... } }
      for _, entry in ipairs(data) do
        if entry.siteId and entry.synonyms and type(entry.synonyms) == "table" then
          state.search_synonyms[entry.siteId] = {}
          for _, row in ipairs(entry.synonyms) do
            if row.term and row.words then
              state.search_synonyms[entry.siteId][row.term:lower()] = {}
              for _, w in ipairs(row.words) do
                table.insert(state.search_synonyms[entry.siteId][row.term:lower()], w:lower())
              end
            end
          end
        end
      end
    end
    
    local function load_stopwords()
      if not SEARCH_STOPWORDS_PATH or SEARCH_STOPWORDS_PATH == "" or not json_ok then
        return
      end
      local f = io.open(SEARCH_STOPWORDS_PATH, "r")
      if not f then
        return
      end
      local ok, data = pcall(cjson.decode, f:read "*a")
      f:close()
      if not ok or type(data) ~= "table" then
        return
      end
      -- expected format: [ { siteId="...", words=["a","the","and"] }, ... ]
      for _, entry in ipairs(data) do
        if entry.siteId and entry.words and type(entry.words) == "table" then
          state.search_stopwords[entry.siteId] = {}
          for _, w in ipairs(entry.words) do
            state.search_stopwords[entry.siteId][w:lower()] = true
          end
        end
      end
    end
    
    load_rates()
    load_synonyms()
    load_stopwords()
    
    -- PII redaction for audit logs ------------------------------------------
    local pii_keys = {
      email = true,
      Email = true,
      phone = true,
      Phone = true,
      Address = true,
      address = true,
      subject = true,
      Subject = true,
    }
    
    local function scrub_pii(obj, depth)
      if depth > 3 then
        return obj
      end
      if type(obj) ~= "table" then
        return obj
      end
      local copy = {}
      for k, v in pairs(obj) do
        if pii_keys[k] then
          copy[k] = "[redacted]"
        else
          copy[k] = scrub_pii(v, depth + 1)
        end
      end
      return copy
    end
    
    local _audit_record = audit.record
    audit.record = function(actor, action, msg, resp, meta)
      return _audit_record(actor, action, scrub_pii(msg, 0), scrub_pii(resp, 0), scrub_pii(meta, 0))
    end
    
    local function track_event(site_id, subject, sku, event)
      state.events[site_id] = state.events[site_id] or {}
      local stats = state.events[site_id][sku]
        or { views = 0, add_to_cart = 0, purchases = 0, last_ts = 0 }
      if event == "view" then
        stats.views = stats.views + 1
      elseif event == "add_to_cart" then
        stats.add_to_cart = stats.add_to_cart + 1
      elseif event == "purchase" then
        stats.purchases = stats.purchases + 1
      end
      stats.last_ts = os.time()
      state.events[site_id][sku] = stats
    
      if subject then
        state.recent[subject] = state.recent[subject] or {}
        local list = state.recent[subject]
        for i = #list, 1, -1 do
          if list[i].sku == sku and list[i].siteId == site_id then
            table.remove(list, i)
          end
        end
        table.insert(list, 1, { siteId = site_id, sku = sku })
        while #list > RECENT_LIMIT do
          table.remove(list)
        end
      end
    
      state.event_log[site_id] = state.event_log[site_id] or {}
      local log = state.event_log[site_id]
      table.insert(log, 1, { ts = os.time(), sku = sku, event = event })
      while #log > EVENT_LOG_LIMIT do
        table.remove(log)
      end
    
      return stats
    end
    
    local function recency_weight(site_id, sku)
      local stats = state.events[site_id] and state.events[site_id][sku]
      local last_ts = stats and stats.last_ts
      if not last_ts then
        return 1
      end
      local age_hours = math.max(0, (os.time() - last_ts) / 3600)
      if age_hours <= 24 then
        return 1.5
      end
      if age_hours <= 72 then
        return 1.2
      end
      if age_hours <= 168 then
        return 1.0
      end
      return 0.8
    end
    
    local function typo_match(text, tokens)
      text = text:lower()
      for _, t in ipairs(tokens) do
        if text:find(t, 1, true) then
          return true
        end
      end
      return false
    end
    
    local function check_rate_limit(key)
      local now = os.time()
      local bucket = state.rate_limits[key]
      if not bucket or now - bucket.window_start >= RATE_LIMIT_WINDOW then
        state.rate_limits[key] = { count = 1, window_start = now }
        return true
      end
      bucket.count = bucket.count + 1
      if bucket.count > RATE_LIMIT_MAX then
        return false
      end
      return true
    end
    
    local function normalize_provider(p)
      if p == "apple_pay" or p == "google_pay" then
        return "stripe"
      end
      return p or "internal"
    end
    
    local function create_payment_intent_internal(args)
      -- args: siteId, checkoutId?, orderId?, amount, currency, method, require3ds?, provider?, token?, subject?
      local payment_id = gen_id "pay"
      local requires_action = (args.require3ds == true) or SCA_FORCE
      local status = requires_action and "requires_action" or "authorized"
      local ok_psp, provider_payload = psp_call(normalize_provider(args.provider), "create_intent", {
        id = payment_id,
        amount = args.amount,
        currency = args.currency,
        token = args.token,
        require3ds = args.require3ds,
        subject = args.subject,
        mode = PSP_MODE,
      })
      if not ok_psp then
        -- fallback to internal stub if allowed
        if PSP_ALLOW_STUB then
          ok_psp, provider_payload = psp_call("internal", "create_intent", {
            id = payment_id,
            amount = args.amount,
            currency = args.currency,
            token = args.token,
            require3ds = args.require3ds,
            subject = args.subject,
            mode = PSP_MODE,
          })
        end
        if not ok_psp then
          return nil, provider_payload or "PSP_ERROR"
        end
      end
      local record = {
        paymentId = payment_id,
        siteId = args.siteId,
        checkoutId = args.checkoutId,
        orderId = args.orderId,
        amount = args.amount,
        currency = args.currency,
        method = args.method,
        provider = ok_psp and normalize_provider(args.provider) or "internal",
        token = args.token,
        subject = args.subject,
        status = status,
        requiresAction = provider_payload.requiresAction or requires_action,
        providerPaymentId = provider_payload.providerPaymentId,
        clientSecret = provider_payload.clientSecret or ("sec_" .. payment_id),
        nextActionUrl = provider_payload.nextActionUrl
          or (requires_action and (THREE_DS_URL .. payment_id) or nil),
        createdAt = os.time(),
      }
      state.payments[payment_id] = record
      state.payment_attempts[payment_id] = {
        {
          ts = os.time(),
          event = "created",
          status = status,
          amount = args.amount,
          provider = record.provider,
        },
      }
      if args.checkoutId and state.checkouts[args.checkoutId] then
        local chk = state.checkouts[args.checkoutId]
        chk.paymentIntent = payment_id
        chk.paymentStatus = status
      end
      if args.orderId and state.orders[args.orderId] then
        state.orders[args.orderId].paymentStatus = status
      end
      return record
    end
    
    local function record_telemetry(kind, data)
      table.insert(state.telemetry, {
        ts = os.time(),
        kind = kind,
        data = data,
      })
    end
    
    local function http_post_json(url, payload, opts)
      opts = opts or {}
      if not json_ok then
        return nil, "JSON_ENCODE_DISABLED"
      end
      local ok_enc, body = pcall(cjson.encode, payload)
      if not ok_enc or not body then
        return nil, "ENCODE_FAILED"
      end
      local tmp = os.tmpname()
      local f = io.open(tmp, "w")
      if not f then
        return nil, "TMP_OPEN_FAILED"
      end
      f:write(body)
      f:close()
    
      local header_flags = "-H 'Content-Type: application/json'"
      if opts.headers then
        for k, v in pairs(opts.headers) do
          if v and v ~= "" then
            header_flags = header_flags .. string.format(" -H '%s: %s'", k, v)
          end
        end
      end
      if opts.Authorization then
        header_flags = header_flags .. string.format(" -H 'Authorization: %s'", opts.Authorization)
      end
      if opts.bearer then
        header_flags = header_flags .. string.format(" -H 'Authorization: Bearer %s'", opts.bearer)
      end
      if
        not opts.Authorization
        and not opts.bearer
        and CARRIER_API_TOKEN
        and CARRIER_API_URL
        and url:find(CARRIER_API_URL, 1, true)
      then
        header_flags = header_flags
          .. string.format(" -H 'Authorization: Bearer %s'", CARRIER_API_TOKEN)
      end
    
      local timeout = opts.timeout or HTTP_TIMEOUT
      local connect_timeout = opts.connect_timeout or HTTP_CONNECT_TIMEOUT
      local cmd = string.format(
        "curl -sS --max-time %d --connect-timeout %d -X POST %s %s --data-binary @%s",
        timeout,
        connect_timeout,
        header_flags,
        url,
        tmp
      )
      local reader = io.popen(cmd, "r")
      if not reader then
        os.remove(tmp)
        return nil, "CURL_READ_FAILED"
      end
      local out = reader:read "*a"
      local ok_close, why, code = reader:close()
      os.remove(tmp)
      if not ok_close then
        return nil, "CURL_EXIT_" .. tostring(code or why)
      end
      if opts.decode == false then
        return out, nil
      end
      if json_ok then
        local ok_dec, obj = pcall(cjson.decode, out)
        if ok_dec then
          return obj, nil
        end
      end
      return out, nil
    end
    
    local function s3_copy_with_retry(path, bucket)
      if not bucket or bucket == "" then
        return false
      end
      for _ = 1, (S3_RETRIES + 1) do
        local cmd = string.format(
          "aws s3 cp %s s3://%s/ --no-progress --expected-size %d --cli-read-timeout %d --cli-connect-timeout %d",
          path,
          bucket,
          0,
          S3_TIMEOUT,
          S3_TIMEOUT
        )
        local rc = os.execute(cmd)
        if rc == true or rc == 0 then
          return true
        end
      end
      return false
    end
    
    local function render_invoice_pdf(inv)
      if not INVOICE_PDF_DIR or INVOICE_PDF_DIR == "" then
        return nil
      end
      os.execute("mkdir -p " .. INVOICE_PDF_DIR)
      local html_path = string.format("%s/%s.html", INVOICE_PDF_DIR, inv.invoiceId)
      local pdf_path = string.format("%s/%s.pdf", INVOICE_PDF_DIR, inv.invoiceId)
      local f = io.open(html_path, "w")
      if f then
        f:write "<html><body>"
        f:write(string.format("<h1>Invoice %s</h1>", inv.invoiceNumber or inv.invoiceId))
        f:write(string.format("<p>Order: %s</p>", inv.orderId or "-"))
        f:write(string.format("<p>Total: %.2f %s</p>", inv.total or 0, inv.currency or ""))
        f:write "<ul>"
        for _, line in ipairs(inv.lines or {}) do
          f:write(
            string.format(
              "<li>%s x%s @ %s</li>",
              line.sku or line.Sku or "item",
              line.qty or line.Qty or "1",
              line.unit_price or line.price or "?"
            )
          )
        end
        f:write "</ul>"
        f:write(string.format("<p>Tax: %.2f Shipping: %.2f</p>", inv.tax or 0, inv.shipping or 0))
        f:write "</body></html>"
        f:close()
      end
      -- best-effort render command
      local cmd = string.format("%s %s %s", PDF_RENDER_CMD, html_path, pdf_path)
      os.execute(cmd)
      local pdf_exists = io.open(pdf_path, "r")
      if pdf_exists then
        pdf_exists:close()
        return pdf_path
      end
      return nil
    end
    
    local function risk_score(checkout)
      local score = 0
      if checkout.quote.total and checkout.quote.total > 500 then
        score = score + 20
      end
      if checkout.address and checkout.address.Country and checkout.address.Country ~= "US" then
        score = score + 10
      end
      if checkout.email and checkout.email:match "@(mailinator|10minutemail|tempmail)" then
        score = score + 25
      end
      if checkout.quote and checkout.quote.shipping and checkout.quote.shipping.rate == 0 then
        score = score + 5
      end
      if checkout.quote and checkout.quote.promo then
        score = score + 5
      end
      return math.min(100, score)
    end
    
    local function build_label(carrier, service, weight, dims)
      local shipment_id = gen_id "ship"
      local tracking = string.format("trk-%s-%04d", carrier or "std", math.random(0, 9999))
      local label_url = string.format("%s%s.pdf", CARRIER_LABEL_BASE, shipment_id)
      local track_url = string.format("%s%s", CARRIER_TRACK_BASE, tracking)
      local label = {
        shipmentId = shipment_id,
        tracking = tracking,
        trackingUrl = track_url,
        labelUrl = label_url,
        carrier = carrier,
        service = service,
        weight = weight,
        dimensions = dims,
        status = "label_created",
      }
      -- optional remote label creation
      if CARRIER_LABEL_API_URL and json_ok then
        local payload = {
          carrier = carrier,
          service = service,
          tracking = tracking,
          shipmentId = shipment_id,
          weight = weight,
        }
        local resp = http_post_json(CARRIER_LABEL_API_URL, payload, {
          Authorization = CARRIER_LABEL_API_KEY and ("Bearer " .. CARRIER_LABEL_API_KEY) or nil,
        })
        if resp and type(resp) == "table" then
          label.labelUrl = resp.labelUrl or label.labelUrl
          label.tracking = resp.tracking or label.tracking
          label.trackingUrl = resp.trackingUrl or label.trackingUrl
        end
      elseif CARRIER_API_URL and json_ok then
        http_post_json(CARRIER_API_URL .. "/label", {
          carrier = carrier,
          service = service,
          tracking = tracking,
          shipmentId = shipment_id,
          weight = weight,
        })
      end
      return label
    end
    
    -- B2B helpers -------------------------------------------------------------
    local function ensure_company(company_id)
      if not state.companies[company_id] then
        return false, "Company not found"
      end
      return true
    end
    
    local function require_company_role(company_id, user_id, roles)
      local comp = state.companies[company_id]
      if not comp then
        return false, "Company not found"
      end
      local role = comp.users and comp.users[user_id]
      for _, r in ipairs(roles) do
        if role == r then
          return true
        end
      end
      return false, "User not authorized for company"
    end
    
    -- tiny Levenshtein for typo tolerance on short queries
    local function levenshtein(a, b)
      if not a or not b then
        return 99
      end
      local la, lb = #a, #b
      if la == 0 then
        return lb
      end
      if lb == 0 then
        return la
      end
      local prev = {}
      for j = 0, lb do
        prev[j] = j
      end
      for i = 1, la do
        local cur = {}
        cur[0] = i
        for j = 1, lb do
          local cost = (a:byte(i) == b:byte(j)) and 0 or 1
          cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev = cur
      end
      return prev[lb]
    end
    
    function handlers.GetProduct(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Sku", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_sku, err_sku = validation.check_length(msg.Sku, 128, "Sku")
      if not ok_len_sku then
        return codec.error("INVALID_INPUT", err_sku, { field = "Sku" })
      end
      local key = ids.product_key(msg["Site-Id"], msg.Sku)
      local product = state.products[key]
      if not product then
        return codec.error("NOT_FOUND", "Product not found", { sku = msg.Sku })
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        sku = msg.Sku,
        payload = product.payload,
        version = product.version or state.active_versions[msg["Site-Id"]] or "active",
        variants = state.variants[msg["Site-Id"]] and state.variants[msg["Site-Id"]][msg.Sku],
        stats = state.events[msg["Site-Id"]] and state.events[msg["Site-Id"]][msg.Sku],
      }
    end
    
    local function calculate_tax_breakdown(site_id, address, cart, shipping_rate)
      local tax = 0
      local line_taxes = {}
      local subtotal_ex = 0
      local reverse_charge = false
      local nexus_states = parse_set(US_NEXUS_STATES)
      local us_taxable = true
      if address.Country == "US" and next(nexus_states) and address.Region then
        us_taxable = nexus_states[address.Region:upper()] == true
      end
      if
        is_eu(MERCHANT_COUNTRY)
        and is_eu(address.Country)
        and address.Country:upper() ~= MERCHANT_COUNTRY
        and is_vat_id_valid(address.VatId or address.VAT or address.VATID)
      then
        reverse_charge = true
      end
      for _, line in ipairs(cart.lines) do
        local rule, rate = pick_tax_rule(site_id, address, line.taxClass)
        local incl = (line.taxInclusive == true) or (rule and rule.taxInclusive == true)
        local line_net = line.line_total
        local lt = 0
        if rate > 0 and not reverse_charge and us_taxable then
          if incl then
            local divisor = 1 + rate / 100
            line_net = line.line_total / divisor
            lt = line.line_total - line_net
          else
            lt = line.line_total * rate / 100
          end
        end
        subtotal_ex = subtotal_ex + line_net
        tax = tax + lt
        table.insert(line_taxes, {
          sku = line.sku,
          tax = lt,
          taxRate = rate,
          taxInclusive = incl,
        })
      end
      local shipping_tax = 0
      if shipping_rate and shipping_rate > 0 then
        local rule, rate = pick_tax_rule(site_id, address, nil)
        local taxable = not (rule and rule.shippingTaxable == false)
        if rate > 0 and taxable and not reverse_charge and us_taxable then
          shipping_tax = shipping_rate * rate / 100
        end
      end
      return tax, line_taxes, subtotal_ex, shipping_tax, reverse_charge
    end
    
    function handlers.ListCategoryProducts(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Category-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Category-Id",
        "Page",
        "PageSize",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_cat, err_cat = validation.check_length(msg["Category-Id"], 128, "Category-Id")
      if not ok_len_cat then
        return codec.error("INVALID_INPUT", err_cat, { field = "Category-Id" })
      end
      local key = ids.category_key(msg["Site-Id"], msg["Category-Id"])
      local category = state.categories[key]
      if not category then
        return codec.error("NOT_FOUND", "Category not found", { category = msg["Category-Id"] })
      end
      local page = msg.Page or 1
      local page_size = msg.PageSize or 50
      if page < 1 then
        page = 1
      end
      if page_size < 1 then
        page_size = 1
      end
      if page_size > 200 then
        page_size = 200
      end
      local start = (page - 1) * page_size + 1
      local finish = start + page_size - 1
      local products = {}
      for i = start, math.min(finish, #category.products) do
        local sku = category.products[i]
        local pkey = ids.product_key(msg["Site-Id"], sku)
        if state.products[pkey] then
          table.insert(products, { sku = sku, payload = state.products[pkey].payload })
        end
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        categoryId = msg["Category-Id"],
        page = page,
        pageSize = page_size,
        items = products,
        total = #category.products,
      }
    end
    
    function handlers.SearchCatalog(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if not check_rate_limit("search:" .. (msg.Subject or msg["Site-Id"])) then
        return codec.error("RATE_LIMITED", "Too many search requests")
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Query",
        "Segment",
        "MinPrice",
        "MaxPrice",
        "Locale",
        "Available",
        "Category-Id",
        "Sort",
        "Currency",
        "Carrier",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      if msg.Query then
        local ok_len_query, err_query = validation.check_length(msg.Query, 1024, "Query")
        if not ok_len_query then
          return codec.error("INVALID_INPUT", err_query, { field = "Query" })
        end
      end
      local min_price = msg.MinPrice
      local max_price = msg.MaxPrice
      if min_price and type(min_price) ~= "number" then
        return codec.error("INVALID_INPUT", "MinPrice must be number")
      end
      if max_price and type(max_price) ~= "number" then
        return codec.error("INVALID_INPUT", "MaxPrice must be number")
      end
      local q = msg.Query and msg.Query:lower() or ""
      local sort = msg.Sort or "relevance"
      local tokens = {}
      for t in q:gmatch "%S+" do
        table.insert(tokens, t)
      end
      local syn = state.search_synonyms[msg["Site-Id"]] or {}
      local stopwords = state.search_stopwords[msg["Site-Id"]] or {}
      local filtered_tokens = {}
      for _, t in ipairs(tokens) do
        if not stopwords[t] then
          table.insert(filtered_tokens, t)
        end
      end
      local expanded_tokens = {}
      for _, t in ipairs(filtered_tokens) do
        table.insert(expanded_tokens, t)
        if syn[t] then
          for _, s in ipairs(syn[t]) do
            table.insert(expanded_tokens, s)
          end
        end
      end
      local results = {}
      local suggestions = {}
      local facets = {
        categories = {},
        availability = { available = 0, unavailable = 0 },
        shippingStatus = {},
        price = { lt25 = 0, lt100 = 0, gte100 = 0 },
        currency = {},
        locales = {},
        carriers = {},
        brands = {},
        tags = {},
      }
      local prefix = "product:" .. msg["Site-Id"] .. ":"
      local flags = state.feature_flags and state.feature_flags[msg["Site-Id"]] or {}
      local segment = msg.Segment
      for key, product in pairs(state.products) do
        if key:sub(1, #prefix) == prefix then
          local sku = key:match "product:[^:]+:(.+)"
          local text = (product.payload.name or ""):lower()
            .. " "
            .. (product.payload.description or ""):lower()
          local matched = (q == "") or text:find(q, 1, true) or typo_match(text, expanded_tokens)
          local fuzzy_hit = false
          if (not matched) and q ~= "" and #q <= 16 then
            local d = levenshtein((product.payload.name or ""):lower(), q)
            fuzzy_hit = d <= 2
          end
          if matched or fuzzy_hit then
            local payload = product.payload or {}
            local price = payload.price
            local locale = payload.locale or payload.Locale
            local available = payload.is_available or payload.available
            local required_flags = payload.flags and payload.flags.required
            local segments = payload.segments
            if required_flags and type(required_flags) == "table" then
              local all_on = true
              for _, f in ipairs(required_flags) do
                if not (flags and flags[f]) then
                  all_on = false
                end
              end
              if not all_on then
                break
              end
            end
            if segments and segment then
              local ok_seg = false
              for _, s in ipairs(segments) do
                if s == segment then
                  ok_seg = true
                end
              end
              if not ok_seg then
                break
              end
            end
            if not available and state.inventory[msg["Site-Id"]] then
              local inv = state.inventory[msg["Site-Id"]] or {}
              local qty = 0
              for _, wh in pairs(inv) do
                qty = qty + (wh[sku] or 0)
              end
              available = qty > 0
            end
            local ok_price = true
            if min_price and price and price < min_price then
              ok_price = false
            end
            if max_price and price and price > max_price then
              ok_price = false
            end
            local ok_locale = (not msg.Locale) or (locale == msg.Locale)
            local ok_currency = (not msg.Currency) or (payload.currency == msg.Currency)
            local ok_available = (msg.Available == nil) or (available == msg.Available)
            local ok_carrier = (not msg.Carrier) or (payload.carrier == msg.Carrier)
            if available then
              facets.availability.available = facets.availability.available + 1
            else
              facets.availability.unavailable = facets.availability.unavailable + 1
            end
            if payload.categoryId then
              facets.categories[payload.categoryId] = (facets.categories[payload.categoryId] or 0) + 1
            end
            if payload.carrier then
              facets.carriers[payload.carrier] = (facets.carriers[payload.carrier] or 0) + 1
            end
            if payload.shippingStatus then
              facets.shippingStatus[payload.shippingStatus] = (
                facets.shippingStatus[payload.shippingStatus] or 0
              ) + 1
            end
            local price_num = tonumber(price or 0) or 0
            if price_num < 25 then
              facets.price.lt25 = facets.price.lt25 + 1
            elseif price_num < 100 then
              facets.price.lt100 = facets.price.lt100 + 1
            else
              facets.price.gte100 = facets.price.gte100 + 1
            end
            if payload.currency then
              facets.currency[payload.currency] = (facets.currency[payload.currency] or 0) + 1
            end
            if locale then
              facets.locales[locale] = (facets.locales[locale] or 0) + 1
            end
            if payload.brand then
              facets.brands[payload.brand] = (facets.brands[payload.brand] or 0) + 1
            end
            if payload.tags and type(payload.tags) == "table" then
              for _, tag in ipairs(payload.tags) do
                if type(tag) == "string" then
                  facets.tags[tag] = (facets.tags[tag] or 0) + 1
                end
              end
            end
            local ok_cat = not msg["Category-Id"]
              or (payload.categoryId == msg["Category-Id"])
              or (payload.category and payload.category.id == msg["Category-Id"])
              or false
            if ok_price and ok_locale and ok_currency and ok_available and ok_carrier and ok_cat then
              local score = 0
              local events = state.events[msg["Site-Id"]] and state.events[msg["Site-Id"]][sku] or {}
              if q ~= "" then
                if sku:lower():find("^" .. q, 1, false) then
                  score = score + 5
                end
                if (payload.name or ""):lower():find(q, 1, true) then
                  score = score + 3
                end
                if (payload.description or ""):lower():find(q, 1, true) then
                  score = score + 1
                end
                -- typo tolerance for short queries (distance <=1)
                if #q <= 6 then
                  local d = levenshtein((payload.name or ""):lower(), q)
                  if d == 1 then
                    score = score + 2
                  end
                end
                if fuzzy_hit then
                  score = score + 1
                end
                for _, tok in ipairs(expanded_tokens) do
                  if (payload.brand or ""):lower():find(tok, 1, true) then
                    score = score + 2
                  end
                  if payload.tags and type(payload.tags) == "table" then
                    for _, tag in ipairs(payload.tags) do
                      if type(tag) == "string" and tag:lower() == tok then
                        score = score + 1
                      end
                    end
                  end
                  -- lightweight token typo for short tokens
                  if #tok <= 5 then
                    local d2 = levenshtein((payload.name or ""):lower(), tok)
                    if d2 == 1 then
                      score = score + 1
                    end
                  end
                end
              end
              local rw = recency_weight(msg["Site-Id"], sku)
              score = score + ((events.purchases or 0) * 2 + (events.views or 0) * 0.1) * rw
              if msg.Locale and locale == msg.Locale then
                score = score + 1
              end
              if msg.Segment and segments then
                score = score + 1
              end
              table.insert(results, {
                sku = sku,
                payload = payload,
                price = price,
                name = payload.name or sku,
                score = score,
                available = available,
                category = payload.categoryId or (payload.category and payload.category.id),
              })
            elseif q ~= "" and not matched then
              local name = (product.payload.name or ""):lower()
              local d = levenshtein(name, q)
              if d <= 2 then
                table.insert(suggestions, product.payload.name or sku)
              end
            end
          end
        end
        -- continue removed
      end
      table.sort(results, function(a, b)
        if sort == "price" or sort == "price_asc" then
          return (a.price or 0) < (b.price or 0)
        end
        if sort == "-price" or sort == "price_desc" then
          return (a.price or 0) > (b.price or 0)
        end
        if sort == "name" then
          return tostring(a.name) < tostring(b.name)
        end
        if sort == "popularity" then
          if (a.score or 0) ~= (b.score or 0) then
            return (a.score or 0) > (b.score or 0)
          end
          return (a.price or 0) < (b.price or 0)
        end
        if sort == "available" then
          if a.available ~= b.available then
            return a.available and not b.available
          end
          -- fall back to relevance if availability matches
          if a.score ~= b.score then
            return (a.score or 0) > (b.score or 0)
          end
          return (a.price or 0) < (b.price or 0)
        end
        if sort == "newest" then
          return (a.payload.updatedAt or 0) > (b.payload.updatedAt or 0)
        end
        -- default relevance
        if a.score ~= b.score then
          return (a.score or 0) > (b.score or 0)
        end
        return (a.price or 0) < (b.price or 0)
      end)
      return codec.ok {
        siteId = msg["Site-Id"],
        query = q,
        items = results,
        total = #results,
        facets = facets,
        suggestions = suggestions,
      }
    end
    
    function handlers.TrackCatalogEvent(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku", "Event" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if not check_rate_limit("event:" .. (msg.Subject or msg["Site-Id"])) then
        return codec.error("RATE_LIMITED", "Too many events")
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Sku",
        "Event",
        "Subject",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_sku, err_sku = validation.check_length(msg.Sku, 128, "Sku")
      if not ok_len_sku then
        return codec.error("INVALID_INPUT", err_sku, { field = "Sku" })
      end
      if msg.Subject then
        local ok_len_sub, err_sub = validation.check_length(msg.Subject, 128, "Subject")
        if not ok_len_sub then
          return codec.error("INVALID_INPUT", err_sub, { field = "Subject" })
        end
      end
      local ev = msg.Event
      if ev ~= "view" and ev ~= "add_to_cart" and ev ~= "purchase" then
        return codec.error("INVALID_INPUT", "Event must be view|add_to_cart|purchase")
      end
      local key = ids.product_key(msg["Site-Id"], msg.Sku)
      if not state.products[key] then
        return codec.error("NOT_FOUND", "Product not found", { sku = msg.Sku })
      end
      local stats = track_event(msg["Site-Id"], msg.Subject, msg.Sku, ev)
      record_telemetry("catalog_event", {
        siteId = msg["Site-Id"],
        sku = msg.Sku,
        subject = msg.Subject,
        event = ev,
      })
      audit.record("catalog", "TrackCatalogEvent", msg, nil, { event = ev, sku = msg.Sku })
      metrics.inc("catalog.TrackCatalogEvent." .. ev)
      metrics.tick()
      return codec.ok {
        siteId = msg["Site-Id"],
        sku = msg.Sku,
        stats = stats,
        recent = state.recent[msg.Subject],
      }
    end
    
    function handlers.RelatedProducts(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Sku",
        "Limit",
        "Format",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local key = ids.product_key(msg["Site-Id"], msg.Sku)
      if not state.products[key] then
        return codec.error("NOT_FOUND", "Product not found", { sku = msg.Sku })
      end
      local limit = tonumber(msg.Limit) or 5
      if limit < 1 then
        limit = 1
      end
      if limit > 20 then
        limit = 20
      end
    
      local scores = state.events[msg["Site-Id"]] or {}
      local ranked = {}
      for sku, s in pairs(scores) do
        if sku ~= msg.Sku then
          local score = (s.views or 0) + 3 * (s.add_to_cart or 0) + 5 * (s.purchases or 0)
          local pkey = ids.product_key(msg["Site-Id"], sku)
          if state.products[pkey] then
            table.insert(ranked, { sku = sku, score = score, payload = state.products[pkey].payload })
          end
        end
      end
      table.sort(ranked, function(a, b)
        if a.score == b.score then
          return tostring(a.sku) < tostring(b.sku)
        end
        return a.score > b.score
      end)
      while #ranked > limit do
        table.remove(ranked)
      end
      if msg.Format == "json" then
        return codec.ok {
          siteId = msg["Site-Id"],
          sku = msg.Sku,
          items = ranked,
          total = #ranked,
          format = "json",
        }
      end
      if msg.Format == "csv" then
        local lines = { "sku,score" }
        for _, r in ipairs(ranked) do
          table.insert(lines, string.format("%s,%s", r.sku, r.score or 0))
        end
        return codec.ok {
          siteId = msg["Site-Id"],
          sku = msg.Sku,
          format = "csv",
          body = table.concat(lines, "\n"),
        }
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        sku = msg.Sku,
        items = ranked,
        total = #ranked,
        facets = { events = state.events[msg["Site-Id"]] and state.events[msg["Site-Id"]][msg.Sku] },
        format = "json",
      }
    end
    
    function handlers.RecentlyViewed(msg)
      local ok, missing = validation.require_fields(msg, { "Subject" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Subject",
        "Site-Id",
        "Limit",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local list = state.recent[msg.Subject] or {}
      local limit = tonumber(msg.Limit) or 10
      if limit < 1 then
        limit = 1
      end
      if limit > RECENT_LIMIT then
        limit = RECENT_LIMIT
      end
      local items = {}
      for _, entry in ipairs(list) do
        if #items >= limit then
          break
        end
        if (not msg["Site-Id"]) or entry.siteId == msg["Site-Id"] then
          local pkey = ids.product_key(entry.siteId, entry.sku)
          local product = state.products[pkey]
          if product then
            table.insert(items, { siteId = entry.siteId, sku = entry.sku, payload = product.payload })
          end
        end
      end
      return codec.ok { subject = msg.Subject, items = items, total = #items }
    end
    
    function handlers.GetRecommendations(msg)
      local limit = msg.Limit or 10
      return handlers.RelatedProducts { ["Site-Id"] = msg["Site-Id"], Sku = msg.Sku, Limit = limit }
    end
    
    function handlers.Bestsellers(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Limit",
        "Format",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit) or 10
      if limit < 1 then
        limit = 1
      end
      if limit > 50 then
        limit = 50
      end
      local scores = state.events[msg["Site-Id"]] or {}
      local ranked = {}
      for sku, s in pairs(scores) do
        local score = (s.purchases or 0) * 4 + (s.add_to_cart or 0) * 2 + (s.views or 0) * 0.2
        score = score * recency_weight(msg["Site-Id"], sku)
        if score > 0 then
          local pkey = ids.product_key(msg["Site-Id"], sku)
          if state.products[pkey] then
            table.insert(ranked, { sku = sku, score = score, payload = state.products[pkey].payload })
          end
        end
      end
      table.sort(ranked, function(a, b)
        if a.score == b.score then
          return tostring(a.sku) < tostring(b.sku)
        end
        return a.score > b.score
      end)
      while #ranked > limit do
        table.remove(ranked)
      end
      if msg.Format == "csv" then
        local lines = { "sku,score" }
        for _, r in ipairs(ranked) do
          table.insert(lines, string.format("%s,%s", r.sku, r.score or 0))
        end
        return codec.ok { siteId = msg["Site-Id"], format = "csv", body = table.concat(lines, "\n") }
      end
      if msg.Format == "json" then
        return codec.ok { siteId = msg["Site-Id"], items = ranked, total = #ranked, format = "json" }
      end
      return codec.ok { siteId = msg["Site-Id"], items = ranked, total = #ranked, format = "json" }
    end
    
    function handlers.TrendingProducts(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Limit",
        "WindowSec",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit) or 10
      if limit < 1 then
        limit = 1
      end
      if limit > 50 then
        limit = 50
      end
      local window = tonumber(msg.WindowSec) or (7 * 24 * 3600)
      local cutoff = os.time() - window
      local log = state.event_log[msg["Site-Id"]] or {}
      local scores = {}
      for _, ev in ipairs(log) do
        if ev.ts >= cutoff then
          local w = (ev.event == "view" and 1)
            or (ev.event == "add_to_cart" and 3)
            or (ev.event == "purchase" and 5)
            or 0
          scores[ev.sku] = (scores[ev.sku] or 0) + w
        else
          break
        end
      end
      local ranked = {}
      for sku, score in pairs(scores) do
        local pkey = ids.product_key(msg["Site-Id"], sku)
        if state.products[pkey] then
          table.insert(ranked, { sku = sku, score = score, payload = state.products[pkey].payload })
        end
      end
      table.sort(ranked, function(a, b)
        if a.score == b.score then
          return tostring(a.sku) < tostring(b.sku)
        end
        return a.score > b.score
      end)
      while #ranked > limit do
        table.remove(ranked)
      end
      return codec.ok { siteId = msg["Site-Id"], items = ranked, total = #ranked, window = window }
    end
    
    function handlers.ExportEventLog(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Limit",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit) or 500
      if limit < 1 then
        limit = 1
      end
      if limit > EVENT_LOG_LIMIT then
        limit = EVENT_LOG_LIMIT
      end
      local log = state.event_log[msg["Site-Id"]] or {}
      local slice = {}
      for i = 1, math.min(limit, #log) do
        table.insert(slice, log[i])
      end
      return codec.ok { siteId = msg["Site-Id"], events = slice, total = #slice }
    end
    
    function handlers.StreamTelemetry(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Events",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      if not (GA4_ENDPOINT and GA4_API_SECRET and GA4_MEASUREMENT_ID) then
        return codec.error("PROVIDER_ERROR", "GA4 not configured")
      end
      local events = msg.Events or state.telemetry
      if type(events) ~= "table" then
        return codec.error("INVALID_INPUT", "Events must be array")
      end
      if #events == 0 then
        return codec.ok { streamed = 0 }
      end
      local payload = {
        client_id = "ao-catalog",
        measurement_id = GA4_MEASUREMENT_ID,
        api_secret = GA4_API_SECRET,
        events = {},
      }
      for _, ev in ipairs(events) do
        table.insert(payload.events, {
          name = ev.kind or "catalog_event",
          params = ev.data or ev,
        })
      end
      local out, err = http_post_json(GA4_ENDPOINT, payload)
      if err then
        return codec.error("PROVIDER_ERROR", err)
      end
      state.telemetry = {}
      return codec.ok { streamed = #payload.events, response = out }
    end
    
    -- Addresses, consents, tokens, credit -----------------------------------
    function handlers.SaveAddress(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Address" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Subject",
        "Address",
        "Label",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      state.address_book[msg.Subject] = state.address_book[msg.Subject] or {}
      table.insert(
        state.address_book[msg.Subject],
        { label = msg.Label or "default", address = msg.Address }
      )
      return codec.ok { subject = msg.Subject, count = #state.address_book[msg.Subject] }
    end
    
    function handlers.ListAddresses(msg)
      local ok, missing = validation.require_fields(msg, { "Subject" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Subject", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      return codec.ok { subject = msg.Subject, addresses = state.address_book[msg.Subject] or {} }
    end
    
    function handlers.SetConsents(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Consents" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Subject", "Consents", "Actor-Role" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      state.consents[msg.Subject] = msg.Consents
      return codec.ok { subject = msg.Subject, consents = msg.Consents }
    end
    
    function handlers.SavePaymentToken(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Provider", "Token", "Last4" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      state.payment_tokens[msg.Subject] = state.payment_tokens[msg.Subject] or {}
      table.insert(state.payment_tokens[msg.Subject], {
        provider = msg.Provider,
        token = msg.Token,
        last4 = msg.Last4,
        brand = msg.Brand,
        exp = msg.Exp,
        default = msg.Default == true,
      })
      return codec.ok { subject = msg.Subject, count = #state.payment_tokens[msg.Subject] }
    end
    
    function handlers.AddStoreCredit(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Amount", "Currency" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local balance = state.store_credit[msg.Subject] or { balance = 0, currency = msg.Currency }
      balance.balance = balance.balance + tonumber(msg.Amount)
      balance.currency = msg.Currency
      state.store_credit[msg.Subject] = balance
      return codec.ok(balance)
    end
    
    function handlers.ApplyStoreCredit(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Checkout-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local credit = state.store_credit[msg.Subject]
      if not credit or credit.balance <= 0 then
        return codec.error("INSUFFICIENT_CREDIT", "No store credit available")
      end
      local checkout = state.checkouts[msg["Checkout-Id"]]
      if not checkout then
        return codec.error("NOT_FOUND", "Checkout not found")
      end
      local apply = math.min(credit.balance, checkout.total or 0)
      credit.balance = credit.balance - apply
      checkout.total = (checkout.total or 0) - apply
      checkout.storeCredit = apply
      return codec.ok { remaining = credit.balance, applied = apply, currency = credit.currency }
    end
    
    function handlers.ExportEvents(msg)
      local ok_extra, extras = validation.require_no_extras(msg, { "Action", "Request-Id", "Site-Id" })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local data = msg["Site-Id"] and (state.event_log[msg["Site-Id"]] or {}) or state.event_log
      -- mock sinks: append newline-delimited JSON to paths if configured
      if TELEMETRY_KAFKA_PATH and json_ok then
        local f = io.open(TELEMETRY_KAFKA_PATH, "a")
        if f then
          f:write(cjson.encode { ts = os.time(), events = data }, "\n")
          f:close()
        end
      end
      if TELEMETRY_S3_PATH and json_ok then
        local f = io.open(TELEMETRY_S3_PATH, "a")
        if f then
          f:write(cjson.encode { ts = os.time(), events = data }, "\n")
          f:close()
        end
      end
      return codec.ok(data)
    end
    
    function handlers.SetFeatureFlags(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Flags" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      state.feature_flags = state.feature_flags or {}
      state.feature_flags[msg["Site-Id"]] = msg.Flags
      return codec.ok { siteId = msg["Site-Id"], flags = msg.Flags }
    end
    
    function handlers.SetEdgeCachePolicy(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Path", "Cache-Control" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      state.edge_cache = state.edge_cache or {}
      state.edge_cache[msg["Site-Id"]] = state.edge_cache[msg["Site-Id"]] or {}
      state.edge_cache[msg["Site-Id"]][msg.Path] = {
        cache_control = msg["Cache-Control"],
        etag = msg.ETag,
        ttl = msg.TTL,
      }
      return codec.ok { siteId = msg["Site-Id"], path = msg.Path }
    end
    
    local function verify_shared_secret(msg, secret)
      if not secret or secret == "" then
        return true
      end
      local sig = msg.Signature or msg.signature or msg.auth or msg["X-Signature"]
      local ts = msg.Timestamp or msg["X-Timestamp"]
      local raw = msg.RawBody
      if raw and sig then
        local expected = hmac_sha256_hex((ts or "") .. "." .. raw, secret)
        if not expected or expected:lower() ~= tostring(sig):lower() then
          return false
        end
        if ts then
          local tnum = tonumber(ts) or 0
          if math.abs(os.time() - tnum) > CARRIER_WEBHOOK_TOLERANCE then
            return false
          end
          local ok_seen = mark_webhook_seen("carrier:" .. (sig or "") .. ":" .. (ts or ""), tnum)
          if not ok_seen then
            return false
          end
        end
        return true
      end
      if not sig then
        return false
      end
      return sig == secret
    end
    
    function handlers.HandlePaymentWebhook(msg)
      -- Accepts payload: Payment-Id, Status (authorized|captured|failed|disputed|refunded), Amount?
      local ok, missing = validation.require_fields(msg, { "Payment-Id", "Status" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if not verify_shared_secret(msg, PAYMENT_WEBHOOK_SECRET) then
        return codec.error("FORBIDDEN", "Invalid webhook signature")
      end
      local pay = state.payments[msg["Payment-Id"]]
      if not pay then
        return codec.error("NOT_FOUND", "Payment not found")
      end
      local status = msg.Status
      local allowed = {
        authorized = true,
        requires_action = true,
        captured = true,
        failed = true,
        disputed = true,
        refunded = true,
      }
      if not allowed[status] then
        return codec.error("INVALID_INPUT", "Unsupported status")
      end
      pay.status = status
      pay.updatedAt = os.time()
      pay.gatewayPayload = msg.Payload or msg.payload
      if status == "captured" then
        pay.capturedAt = os.time()
      end
      if status == "refunded" then
        pay.refundedAt = os.time()
        pay.refundAmount = msg.Amount or pay.amount
      end
      if pay.orderId and state.orders[pay.orderId] then
        state.orders[pay.orderId].paymentStatus = status
        if status == "refunded" then
          state.orders[pay.orderId].refundAmount = msg.Amount or pay.amount
        end
        if status == "disputed" then
          state.orders[pay.orderId].status = "disputed"
        end
      end
      if pay.checkoutId and state.checkouts[pay.checkoutId] then
        state.checkouts[pay.checkoutId].paymentStatus = status
        state.checkouts[pay.checkoutId].status = status == "captured" and "paid" or status
      end
      audit.record(
        "catalog",
        "HandlePaymentWebhook",
        msg,
        nil,
        { paymentId = pay.paymentId, status = status }
      )
      return codec.ok { paymentId = pay.paymentId, status = status }
    end
    
    function handlers.HandleCarrierWebhook(msg)
      local ok, missing = validation.require_fields(msg, { "Shipment-Id", "Status" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if not verify_shared_secret(msg, CARRIER_WEBHOOK_SECRET) then
        return codec.error("FORBIDDEN", "Invalid webhook signature")
      end
      if
        msg.Timestamp
        and math.abs(os.time() - (tonumber(msg.Timestamp) or 0)) > CARRIER_WEBHOOK_TOLERANCE
      then
        return codec.error("FORBIDDEN", "Stale webhook")
      end
      if msg.EventId then
        local ok_seen, err = mark_event_seen("carrier", msg.EventId, tonumber(msg.Timestamp))
        if not ok_seen then
          return codec.error("CONFLICT", "Duplicate webhook", { reason = err })
        end
      end
      state.shipments[msg["Shipment-Id"]] = state.shipments[msg["Shipment-Id"]] or {}
      local sh = state.shipments[msg["Shipment-Id"]]
      sh.status = msg.Status or sh.status
      sh.tracking = msg.Tracking or sh.tracking
      sh.eta = msg.Eta or sh.eta
      sh.updatedAt = os.time()
      record_shipment_event(
        msg["Shipment-Id"],
        sh.status,
        { source = "carrier", tracking = sh.tracking }
      )
      if sh.orderId and state.orders[sh.orderId] then
        local order = state.orders[sh.orderId]
        if sh.status == "delivered" then
          order.status = "delivered"
          notify_customer(
            "shipment.delivered",
            { orderId = sh.orderId, shipmentId = msg["Shipment-Id"] }
          )
        elseif sh.status == "out_for_delivery" then
          order.status = order.status or "out_for_delivery"
          notify_customer("shipment.out_for_delivery", {
            orderId = sh.orderId,
            shipmentId = msg["Shipment-Id"],
            tracking = sh.tracking,
          })
        elseif sh.status == "exception" or sh.status == "delayed" or sh.status == "lost" then
          order.status = "shipment_issue"
          notify_customer("shipment.issue", {
            orderId = sh.orderId,
            shipmentId = msg["Shipment-Id"],
            status = sh.status,
            tracking = sh.tracking,
          })
          state.notification_failures[sh.orderId] = state.notification_failures[sh.orderId] or {}
          table.insert(state.notification_failures[sh.orderId], {
            type = "shipment_issue",
            target = CUSTOMER_WEBHOOK,
            payload = sh,
            attempts = 0,
            ts = os.time(),
            error = "carrier_" .. sh.status,
          })
        end
      end
      audit.record(
        "catalog",
        "HandleCarrierWebhook",
        msg,
        nil,
        { shipmentId = msg["Shipment-Id"], status = sh.status }
      )
      return codec.ok(sh)
    end
    
    local function sign_hmac(body)
      if not JWT_HMAC_SECRET then
        return nil, "SECRET_MISSING"
      end
      return auth.hmac(body, JWT_HMAC_SECRET)
    end
    
    function handlers.SignPayload(msg)
      local ok, missing = validation.require_fields(msg, { "Payload" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Payload",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      if not json_ok then
        return codec.error("PROVIDER_ERROR", "json not available")
      end
      local ok_enc, body = pcall(cjson.encode, msg.Payload)
      if not ok_enc then
        return codec.error("INVALID_INPUT", "Payload not encodable")
      end
      local sig, err = sign_hmac(body)
      if not sig then
        return codec.error("PROVIDER_ERROR", err)
      end
      return codec.ok { signature = sig }
    end
    
    function handlers.VerifySignature(msg)
      local ok, missing = validation.require_fields(msg, { "Payload", "Signature" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if not json_ok then
        return codec.error("PROVIDER_ERROR", "json not available")
      end
      local ok_enc, body = pcall(cjson.encode, msg.Payload)
      if not ok_enc then
        return codec.error("INVALID_INPUT", "Payload not encodable")
      end
      local expected, err = sign_hmac(body)
      if not expected then
        return codec.error("PROVIDER_ERROR", err)
      end
      if expected ~= msg.Signature then
        return codec.error("FORBIDDEN", "Signature mismatch")
      end
      return codec.ok { valid = true }
    end
    
    function handlers.CreateWebhook(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Url", "Events" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Url",
        "Events",
        "Secret",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_events, err_events = validation.assert_type(msg.Events, "table", "Events")
      if not ok_events then
        return codec.error("INVALID_INPUT", err_events, { field = "Events" })
      end
      local id = gen_id "wh"
      state.webhooks[msg["Site-Id"]] = state.webhooks[msg["Site-Id"]] or {}
      state.webhooks[msg["Site-Id"]][id] = {
        url = msg.Url,
        secret = msg.Secret,
        events = msg.Events,
        createdAt = os.time(),
      }
      audit.record("catalog", "CreateWebhook", msg, nil, { siteId = msg["Site-Id"], webhookId = id })
      return codec.ok { webhookId = id }
    end
    
    function handlers.GetWebhook(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Webhook-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Webhook-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local wh = state.webhooks[msg["Site-Id"]] and state.webhooks[msg["Site-Id"]][msg["Webhook-Id"]]
      if not wh then
        return codec.error("NOT_FOUND", "Webhook not found")
      end
      return codec.ok { webhookId = msg["Webhook-Id"], webhook = wh }
    end
    
    function handlers.ListWebhooks(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local list = {}
      for id, wh in pairs(state.webhooks[msg["Site-Id"]] or {}) do
        table.insert(list, { webhookId = id, webhook = wh })
      end
      return codec.ok { siteId = msg["Site-Id"], items = list, total = #list }
    end
    
    function handlers.DeleteWebhook(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Webhook-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Webhook-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      if state.webhooks[msg["Site-Id"]] then
        state.webhooks[msg["Site-Id"]][msg["Webhook-Id"]] = nil
      end
      audit.record("catalog", "DeleteWebhook", msg, nil, { webhookId = msg["Webhook-Id"] })
      return codec.ok { deleted = msg["Webhook-Id"] }
    end
    
    function handlers.ExportCatalogFeed(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Cursor",
        "Limit",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site = msg["Site-Id"]
      if not site then
        return codec.error("INVALID_INPUT", "Site-Id required")
      end
      local cursor = msg.Cursor or ""
      local limit = tonumber(msg.Limit) or 200
      if limit < 1 then
        limit = 1
      end
      if limit > 500 then
        limit = 500
      end
      local prefix = "product:" .. site .. ":"
      local items = {}
      local keys = {}
      for key, _ in pairs(state.products) do
        if key:sub(1, #prefix) == prefix then
          table.insert(keys, key)
        end
      end
      table.sort(keys)
      local start_index = 1
      if cursor ~= "" then
        for i, k in ipairs(keys) do
          if k == cursor then
            start_index = i + 1
            break
          end
        end
      end
      for i = start_index, math.min(#keys, start_index + limit - 1) do
        local key = keys[i]
        table.insert(items, { key = key, payload = state.products[key].payload })
      end
      local next_cursor = (#keys > start_index + limit - 1) and keys[start_index + limit - 1] or nil
      return codec.ok { siteId = site, items = items, nextCursor = next_cursor, total = #items }
    end
    
    function handlers.ExportCategoryFeed(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Cursor",
        "Limit",
        "UpdatedAfter",
        "IncludeDeleted",
        "Path",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site = msg["Site-Id"]
      if not site then
        return codec.error("INVALID_INPUT", "Site-Id required")
      end
      local updated_after = tonumber(msg.UpdatedAfter) or 0
      local cursor = msg.Cursor or ""
      local limit = tonumber(msg.Limit) or 200
      if limit < 1 then
        limit = 1
      end
      if limit > 500 then
        limit = 500
      end
      local prefix = "category:" .. site .. ":"
      local keys = {}
      for key, cat in pairs(state.categories) do
        if key:sub(1, #prefix) == prefix and (cat.updatedAt or 0) >= updated_after then
          table.insert(keys, key)
        end
      end
      table.sort(keys)
      local start_index = 1
      if cursor ~= "" then
        for i, k in ipairs(keys) do
          if k == cursor then
            start_index = i + 1
            break
          end
        end
      end
      local items = {}
      for i = start_index, math.min(#keys, start_index + limit - 1) do
        local key = keys[i]
        local cat = state.categories[key]
        table.insert(items, {
          key = key,
          payload = cat.payload,
          products = cat.products,
          updatedAt = cat.updatedAt,
          categoryId = key:match "category:[^:]+:(.+)",
        })
      end
      if msg.IncludeDeleted and state.category_deletions[site] then
        for _, d in ipairs(state.category_deletions[site]) do
          if (d.deletedAt or 0) >= updated_after then
            table.insert(items, { key = d.key, deletedAt = d.deletedAt, deleted = true })
          end
        end
      end
      local next_cursor = (#keys > start_index + limit - 1) and keys[start_index + limit - 1] or nil
      if msg.Path then
        local f = io.open(msg.Path, "w")
        if f and json_ok then
          for _, item in ipairs(items) do
            local ok_line, line = pcall(cjson.encode, item)
            if ok_line and line then
              f:write(line)
              f:write "\n"
            end
          end
          f:close()
        end
      end
      return codec.ok {
        siteId = site,
        items = items,
        nextCursor = next_cursor,
        total = #items,
        updatedAfter = updated_after,
        includeDeleted = msg.IncludeDeleted or false,
      }
    end
    
    function handlers.ExportSearchFeed(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Cursor",
        "Limit",
        "UpdatedAfter",
        "Path",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site = msg["Site-Id"]
      if not site then
        return codec.error("INVALID_INPUT", "Site-Id required")
      end
      local updated_after = tonumber(msg.UpdatedAfter) or 0
      local limit = tonumber(msg.Limit) or 500
      if limit < 1 then
        limit = 1
      end
      if limit > 2000 then
        limit = 2000
      end
      local cursor = msg.Cursor or ""
      local prefix = "product:" .. site .. ":"
      local keys = {}
      for key, product in pairs(state.products) do
        if key:sub(1, #prefix) == prefix then
          local updated = product.payload.updatedAt or product.payload.updated_at or 0
          if updated >= updated_after then
            table.insert(keys, { key = key, updated = updated })
          end
        end
      end
      table.sort(keys, function(a, b)
        if a.updated == b.updated then
          return a.key < b.key
        end
        return (a.updated or 0) > (b.updated or 0)
      end)
      local start_index = 1
      if cursor ~= "" then
        for i, row in ipairs(keys) do
          if row.key == cursor then
            start_index = i + 1
            break
          end
        end
      end
      local items = {}
      for i = start_index, math.min(#keys, start_index + limit - 1) do
        local row = keys[i]
        table.insert(
          items,
          { key = row.key, updatedAt = row.updated, payload = state.products[row.key].payload }
        )
      end
      -- include deletions as tombstones if requested
      if msg.IncludeDeleted and state.deletions[site] then
        for _, d in ipairs(state.deletions[site]) do
          if (d.deletedAt or 0) >= updated_after then
            table.insert(items, { key = d.key, deletedAt = d.deletedAt, deleted = true })
          end
        end
      end
      local next_cursor = (#keys > start_index + limit - 1) and keys[start_index + limit - 1].key or nil
      -- optional NDJSON export
      if msg.Path or FEED_EXPORT_PATH then
        local path = msg.Path or FEED_EXPORT_PATH
        local f = io.open(path, "w")
        if f and json_ok then
          for _, item in ipairs(items) do
            local ok_line, line = pcall(cjson.encode, item)
            if ok_line and line then
              f:write(line)
              f:write "\n"
            end
          end
          f:close()
        end
      end
      return codec.ok {
        siteId = site,
        items = items,
        nextCursor = next_cursor,
        total = #items,
        updatedAfter = updated_after,
        includeDeleted = msg.IncludeDeleted or false,
      }
    end
    
    function handlers.ExportMerchantFeed(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Limit",
        "Cursor",
        "Path",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site = msg["Site-Id"]
      if not site then
        return codec.error("INVALID_INPUT", "Site-Id required")
      end
      local updated_after = tonumber(msg.UpdatedAfter) or 0
      local limit = tonumber(msg.Limit) or 1000
      if limit < 1 then
        limit = 1
      end
      if limit > 5000 then
        limit = 5000
      end
      local cursor = msg.Cursor or ""
      local prefix = "product:" .. site .. ":"
      local keys = {}
      for key, product in pairs(state.products) do
        if key:sub(1, #prefix) == prefix then
          local updated = product.payload.updatedAt or product.payload.updated_at or 0
          if updated >= updated_after then
            table.insert(keys, { key = key, updated = updated })
          end
        end
      end
      table.sort(keys, function(a, b)
        if a.updated == b.updated then
          return a.key < b.key
        end
        return (a.updated or 0) > (b.updated or 0)
      end)
      local start_index = 1
      if cursor ~= "" then
        for i, row in ipairs(keys) do
          if row.key == cursor then
            start_index = i + 1
            break
          end
        end
      end
      local rows = {}
      for i = start_index, math.min(#keys, start_index + limit - 1) do
        local row = keys[i]
        local p = state.products[row.key].payload
        table.insert(rows, {
          id = p.sku or row.key,
          title = p.name,
          description = p.description,
          link = p.url or p.Link,
          image_link = (p.assets and p.assets[1]) or nil,
          availability = p.available and "in stock" or "out of stock",
          price = string.format("%.2f %s", p.price or 0, p.currency or MERCHANT_CENTER_CURRENCY),
          brand = p.brand,
          gtin = p.gtin,
          mpn = p.mpn,
          condition = p.condition or "new",
          shipping = {
            country = MERCHANT_CENTER_COUNTRY,
            service = p.shippingService or "Standard",
            price = string.format(
              "%.2f %s",
              (p.shipping and p.shipping.price) or 0,
              p.currency or MERCHANT_CENTER_CURRENCY
            ),
          },
          updatedAt = row.updated,
        })
      end
      if msg.IncludeDeleted and state.deletions[site] then
        for _, d in ipairs(state.deletions[site]) do
          if (d.deletedAt or 0) >= updated_after then
            table.insert(rows, { id = d.key, deleted = true, deletedAt = d.deletedAt })
          end
        end
      end
      local next_cursor = (#keys > start_index + limit - 1) and keys[start_index + limit - 1].key or nil
      if msg.Path or MERCHANT_CENTER_PATH then
        local path = msg.Path or MERCHANT_CENTER_PATH
        local f = io.open(path, "w")
        if f then
          for _, r in ipairs(rows) do
            f:write(table.concat({
              r.id,
              r.title or "",
              r.description or "",
              r.link or "",
              r.image_link or "",
              r.availability or "",
              r.price or "",
              r.brand or "",
              r.gtin or "",
              r.mpn or "",
              r.condition or "",
              r.shipping.country or "",
              r.shipping.service or "",
              r.shipping.price or "",
            }, ","))
            f:write "\n"
          end
          f:close()
        end
      end
      return codec.ok {
        siteId = site,
        items = rows,
        nextCursor = next_cursor,
        total = #rows,
        updatedAfter = updated_after,
        includeDeleted = msg.IncludeDeleted or false,
      }
    end
    
    -- Cache purge stub -------------------------------------------------------
    function handlers.PurgeCache(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Path",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local path = msg.Path or "/*"
      local keys = msg.SurrogateKeys or {}
      purge_cache { paths = { path }, keys = keys }
      local result = { purged = path, surrogateKeys = keys }
      audit.record("catalog", "PurgeCache", msg, nil, { siteId = msg["Site-Id"], path = path })
      return codec.ok(result)
    end
    
    function handlers.ApplyOrderEvent(msg)
      local ok, missing = validation.require_fields(msg, { "Event" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing Event", { missing = missing })
      end
      local ev = msg.Event
      if type(ev) ~= "table" or not ev.type then
        return codec.error("INVALID_INPUT", "Event.type required")
      end
      -- allow verification with hmac if present
      msg["Order-Id"] = msg["Order-Id"] or ev.orderId or ev["Order-Id"]
      local ok_hmac, hmac_err = auth.verify_outbox_hmac(msg)
      if not ok_hmac then
        return codec.error("FORBIDDEN", hmac_err)
      end
    
      if ev.type == "OrderCreated" then
        state.orders[ev.orderId] = {
          siteId = ev.siteId,
          customerId = ev.customerId,
          currency = ev.currency,
          totals = ev.totals,
          coupon = ev.coupon,
          coupons = ev.coupons,
          vatRate = ev.vatRate,
          shipping = ev.shipping,
          address = ev.address,
          status = ev.status or "pending",
          updatedAt = os.time(),
        }
      elseif ev.type == "OrderStatusUpdated" then
        local o = state.orders[ev.orderId] or { siteId = ev.siteId }
        o.status = ev.status or o.status
        o.reason = ev.reason or o.reason
        o.updatedAt = os.time()
        state.orders[ev.orderId] = o
      elseif ev.type == "PaymentStatusChanged" then
        if ev.orderId then
          local o = state.orders[ev.orderId] or {}
          o.paymentStatus = ev.status or o.paymentStatus
          if ev.status == "disputed" then
            o.status = o.status or "disputed"
          end
          o.updatedAt = os.time()
          state.orders[ev.orderId] = o
        end
      elseif ev.type == "ShipmentTrackingUpdated" then
        state.shipments[ev.shipmentId] = {
          tracking = ev.tracking,
          carrier = ev.carrier,
          eta = ev.eta,
          status = ev.status,
          orderId = ev.orderId,
          updatedAt = os.time(),
        }
      elseif ev.type == "ReturnUpdated" then
        state.returns[ev.returnId] = {
          status = ev.status,
          reason = ev.reason,
          orderId = ev.orderId,
          updatedAt = os.time(),
        }
      end
      audit.record("catalog", "ApplyOrderEvent", msg, nil, { type = ev.type, orderId = ev.orderId })
      metrics.inc "catalog.ApplyOrderEvent.count"
      metrics.tick()
      return codec.ok { applied = ev.type, orderId = ev.orderId }
    end
    
    function handlers.GetOrder(msg)
      local ok, missing = validation.require_fields(msg, { "Order-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Order-Id required", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Order-Id", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local order = state.orders[msg["Order-Id"]]
      if not order then
        return codec.error("NOT_FOUND", "order not found")
      end
      return codec.ok { orderId = msg["Order-Id"], order = order }
    end
    
    function handlers.ListOrders(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Customer-Id",
        "Status",
        "Limit",
        "Offset",
        "Actor-Role",
        "Schema-Version",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit) or 50
      local offset = tonumber(msg.Offset) or 0
      local items = {}
      for oid, o in pairs(state.orders) do
        if
          (not msg["Site-Id"] or o.siteId == msg["Site-Id"])
          and (not msg["Customer-Id"] or o.customerId == msg["Customer-Id"])
          and (not msg.Status or o.status == msg.Status)
        then
          table.insert(items, { orderId = oid, order = o })
        end
      end
      table.sort(items, function(a, b)
        return (a.order.updatedAt or 0) > (b.order.updatedAt or 0)
      end)
      local slice = {}
      for i = offset + 1, math.min(#items, offset + limit) do
        table.insert(slice, items[i])
      end
      return codec.ok { total = #items, items = slice }
    end
    
    function handlers.SetInventoryReservation(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Items" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Order-Id", "Items", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_items, err_items = validation.assert_type(msg.Items, "table", "Items")
      if not ok_items then
        return codec.error("INVALID_INPUT", err_items, { field = "Items" })
      end
      for _, item in ipairs(msg.Items) do
        if not (item.sku and item.qty) then
          return codec.error("INVALID_INPUT", "Item must have sku and qty")
        end
      end
      state.reservations[msg["Order-Id"]] =
        { siteId = msg["Site-Id"], items = msg.Items, released = false }
      return codec.ok { orderId = msg["Order-Id"], reserved = #msg.Items }
    end
    
    local function adjust_inventory(siteId, items, sign)
      state.inventory[siteId] = state.inventory[siteId] or {}
      local inv = state.inventory[siteId]
      for _, item in ipairs(items or {}) do
        local wh = item.warehouse or "default"
        inv[wh] = inv[wh] or {}
        inv[wh][item.sku] = math.max(0, (inv[wh][item.sku] or 0) + sign * (item.qty or 0))
      end
    end
    
    function handlers.SyncShipment(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Status" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local res = state.reservations[msg["Order-Id"]]
      if res and not res.released and (msg.Status == "shipped" or msg.Status == "delivered") then
        adjust_inventory(res.siteId, res.items, -1)
        res.released = true
      end
      return codec.ok { orderId = msg["Order-Id"], released = res and res.released or false }
    end
    
    function handlers.SyncReturn(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Status" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local res = state.reservations[msg["Order-Id"]]
      if res and (msg.Status == "approved" or msg.Status == "refunded") then
        adjust_inventory(res.siteId, res.items, 1)
      end
      return codec.ok { orderId = msg["Order-Id"], restocked = res ~= nil }
    end
    
    function handlers.GetShippingRates(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local rates = state.shipping_rates[msg["Site-Id"]] or {}
      return codec.ok { siteId = msg["Site-Id"], rates = rates }
    end
    
    function handlers.GetTaxRates(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local rates = state.tax_rates[msg["Site-Id"]] or {}
      return codec.ok { siteId = msg["Site-Id"], rates = rates }
    end
    
    function handlers.ValidateAddress(msg)
      local ok, missing = validation.require_fields(msg, { "Country" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Country",
        "Region",
        "City",
        "Postal",
        "Line1",
        "Line2",
        "Actor-Role",
        "Schema-Version",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      if #msg.Country ~= 2 then
        return codec.error("INVALID_INPUT", "Country must be ISO2")
      end
      local postal_re = os.getenv "ADDRESS_POSTAL_REGEX"
      if postal_re and msg.Postal and not tostring(msg.Postal):match(postal_re) then
        return codec.error("INVALID_INPUT", "Postal format invalid", { field = "Postal" })
      end
    
      local validated = {
        country = msg.Country:upper(),
        region = msg.Region,
        city = msg.City,
        postal = msg.Postal,
        line1 = msg.Line1,
        line2 = msg.Line2,
      }
    
      local cmd = os.getenv "ADDRESS_VALIDATE_CMD"
      if cmd and cmd ~= "" then
        local pipe = io.popen(cmd, "r")
        if pipe then
          local out = pipe:read "*a"
          pipe:close()
          if out and #out > 0 then
            local ok_json, obj = pcall(cjson.decode, out)
            if ok_json and obj and obj.normalized then
              validated = obj.normalized
            elseif os.getenv "ADDRESS_VALIDATE_STRICT" == "1" then
              return codec.error("PROVIDER_ERROR", "address_validate_failed", { output = out })
            end
          elseif os.getenv "ADDRESS_VALIDATE_STRICT" == "1" then
            return codec.error("PROVIDER_ERROR", "address_validate_empty")
          end
        elseif os.getenv "ADDRESS_VALIDATE_STRICT" == "1" then
          return codec.error("PROVIDER_ERROR", "address_validate_io")
        end
      end
    
      return codec.ok {
        valid = true,
        normalized = validated,
      }
    end
    
    function handlers.GetShipment(msg)
      local ok, missing = validation.require_fields(msg, { "Shipment-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Shipment-Id", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local sh = state.shipments[msg["Shipment-Id"]]
      if not sh then
        return codec.error("NOT_FOUND", "Shipment not found")
      end
      return codec.ok(sh)
    end
    
    function handlers.ApplyShipmentEvent(msg)
      local ok, missing = validation.require_fields(msg, { "Shipment-Id", "Order-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Shipment-Id",
        "Order-Id",
        "Carrier",
        "Service",
        "Label-Url",
        "Tracking",
        "Tracking-Url",
        "Eta",
        "Status",
        "Actor-Role",
        "Schema-Version",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      state.shipments[msg["Shipment-Id"]] = state.shipments[msg["Shipment-Id"]] or {}
      local sh = state.shipments[msg["Shipment-Id"]]
      sh.orderId = msg["Order-Id"]
      sh.carrier = msg.Carrier or sh.carrier
      sh.service = msg.Service or sh.service
      sh.labelUrl = msg["Label-Url"] or sh.labelUrl
      sh.tracking = msg.Tracking or sh.tracking
      sh.trackingUrl = msg["Tracking-Url"] or sh.trackingUrl
      sh.eta = msg.Eta or sh.eta
      sh.status = msg.Status or sh.status or "pending"
      record_shipment_event(msg["Shipment-Id"], sh.status, { source = "apply", tracking = sh.tracking })
      audit.record("catalog", "ApplyShipmentEvent", msg, nil, { shipment = msg["Shipment-Id"] })
      return codec.ok {
        shipmentId = msg["Shipment-Id"],
        status = sh.status,
        carrier = sh.carrier,
        service = sh.service,
        labelUrl = sh.labelUrl,
        tracking = sh.tracking,
        trackingUrl = sh.trackingUrl,
        eta = sh.eta,
      }
    end
    
    function handlers.ApplyTrackingEvent(msg)
      local ok, missing = validation.require_fields(msg, { "Shipment-Id", "Tracking" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Shipment-Id",
        "Tracking",
        "Carrier",
        "Eta",
        "Tracking-Url",
        "Status",
        "Actor-Role",
        "Schema-Version",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      state.shipments[msg["Shipment-Id"]] = state.shipments[msg["Shipment-Id"]] or {}
      local sh = state.shipments[msg["Shipment-Id"]]
      sh.tracking = msg.Tracking
      sh.trackingUrl = msg["Tracking-Url"] or sh.trackingUrl
      sh.eta = msg.Eta or sh.eta
      sh.carrier = msg.Carrier or sh.carrier
      sh.status = msg.Status or sh.status
      record_shipment_event(
        msg["Shipment-Id"],
        sh.status or "in_transit",
        { source = "track", tracking = sh.tracking }
      )
      if sh.orderId and sh.status == "in_transit" then
        notify_customer("shipment.in_transit", {
          orderId = sh.orderId,
          shipmentId = msg["Shipment-Id"],
          tracking = sh.tracking,
          eta = sh.eta,
        })
      end
      audit.record(
        "catalog",
        "ApplyTrackingEvent",
        msg,
        nil,
        { shipment = msg["Shipment-Id"], tracking = msg.Tracking }
      )
      return codec.ok {
        shipmentId = msg["Shipment-Id"],
        tracking = sh.tracking,
        trackingUrl = sh.trackingUrl,
        eta = sh.eta,
        status = sh.status,
      }
    end
    
    function handlers.CreateShippingLabel(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Carrier" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Order-Id",
        "Carrier",
        "Service",
        "Dimensions",
        "Address",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local carrier = msg.Carrier
      local service = msg.Service or "standard"
      local order = state.orders[msg["Order-Id"]] or {}
      local ship_to = msg.Address or order.address
      if type(ship_to) ~= "table" or not ship_to.Country then
        return codec.error("INVALID_INPUT", "Address.Country required for label")
      end
      local dims
      if msg.Dimensions then
        local d = msg.Dimensions
        local function dim(name)
          local v = d[name] or d[name:lower()] or d[name:upper()]
          return v and tonumber(v) or nil
        end
        local L, W, H = dim "Length", dim "Width", dim "Height"
        if not (L and W and H) then
          return codec.error("INVALID_INPUT", "Dimensions require Length/Width/Height numbers")
        end
        dims = { length = L, width = W, height = H }
      end
      local weight = 0
      if order.items then
        for _, it in ipairs(order.items) do
          local pkey = ids.product_key(msg["Site-Id"], it.sku or it.Sku or "")
          local payload = state.products[pkey] and state.products[pkey].payload or {}
          weight = weight + (payload.weight or payload.Weight or 0) * (it.qty or it.Qty or 1)
        end
      end
      local label = build_label(carrier, service, weight, dims)
      label.orderId = msg["Order-Id"]
      label.siteId = msg["Site-Id"]
      label.address = ship_to
      label.eta = order.eta
      label.createdAt = os.time()
      state.shipments[label.shipmentId] = label
      audit.record(
        "catalog",
        "CreateShippingLabel",
        msg,
        nil,
        { shipmentId = label.shipmentId, orderId = msg["Order-Id"], carrier = carrier }
      )
      return codec.ok(label)
    end
    
    function handlers.UpsertProduct(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku", "Payload" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Sku",
        "Payload",
        "Version",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_sku, err_sku = validation.check_length(msg.Sku, 128, "Sku")
      if not ok_len_sku then
        return codec.error("INVALID_INPUT", err_sku, { field = "Sku" })
      end
      if msg.Version then
        local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
        if not ok_len_ver then
          return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
        end
      end
      local ok_type_payload, err_type_payload = validation.assert_type(msg.Payload, "table", "Payload")
      if not ok_type_payload then
        return codec.error("INVALID_INPUT", err_type_payload, { field = "Payload" })
      end
      if not msg.Payload.sku then
        msg.Payload.sku = msg.Sku
      end
      if msg.Payload.sku ~= msg.Sku then
        return codec.error("INVALID_INPUT", "Payload sku must match Sku field", { field = "Sku" })
      end
      local payload_len = validation.estimate_json_length(msg.Payload)
      local ok_size, err_size = validation.check_size(payload_len, MAX_PAYLOAD_BYTES, "Payload")
      if not ok_size then
        return codec.error("INVALID_INPUT", err_size, { field = "Payload" })
      end
      if msg.Payload.taxClass and type(msg.Payload.taxClass) ~= "string" then
        return codec.error("INVALID_INPUT", "taxClass must be string", { field = "Payload.taxClass" })
      end
      if msg.Payload.taxClass and #msg.Payload.taxClass > 64 then
        return codec.error("INVALID_INPUT", "taxClass too long", { field = "Payload.taxClass" })
      end
      local ok_schema, schema_err = schema.validate("product", msg.Payload)
      if not ok_schema then
        return codec.error("INVALID_INPUT", "Payload failed schema", { errors = schema_err })
      end
      local key = ids.product_key(msg["Site-Id"], msg.Sku)
      state.products[key] = { payload = msg.Payload, version = msg.Version }
      audit.record("catalog", "UpsertProduct", msg, nil, { sku = msg.Sku })
      purge_cache {
        paths = {
          "/p/" .. msg.Sku,
          "/api/catalog/" .. msg.Sku,
        },
        keys = { "product:" .. msg.Sku },
      }
      -- image pipeline
      if msg.Payload.assets and msg.Payload.assets[1] and IMAGE_RESIZE_CMD then
        local src = msg.Payload.assets[1]
        resize_and_store(msg["Site-Id"], msg.Sku, src)
      end
      return codec.ok { sku = msg.Sku }
    end
    
    function handlers.DeleteProduct(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Sku", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local key = ids.product_key(msg["Site-Id"], msg.Sku)
      state.products[key] = nil
      state.deletions[msg["Site-Id"]] = state.deletions[msg["Site-Id"]] or {}
      table.insert(state.deletions[msg["Site-Id"]], { key = key, deletedAt = os.time() })
      audit.record("catalog", "DeleteProduct", msg, nil, { sku = msg.Sku })
      purge_cache {
        paths = {
          "/p/" .. msg.Sku,
          "/api/catalog/" .. msg.Sku,
        },
        keys = { "product:" .. msg.Sku },
      }
      return codec.ok { deleted = msg.Sku }
    end
    
    function handlers.UpsertVariants(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Parent-Sku", "Variants" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Parent-Sku",
        "Variants",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_parent, err_parent = validation.check_length(msg["Parent-Sku"], 128, "Parent-Sku")
      if not ok_len_parent then
        return codec.error("INVALID_INPUT", err_parent, { field = "Parent-Sku" })
      end
      local ok_type, err_type = validation.assert_type(msg.Variants, "table", "Variants")
      if not ok_type then
        return codec.error("INVALID_INPUT", err_type, { field = "Variants" })
      end
      if #msg.Variants == 0 then
        return codec.error("INVALID_INPUT", "Variants must be non-empty", { field = "Variants" })
      end
      state.variants[msg["Site-Id"]] = state.variants[msg["Site-Id"]] or {}
      state.variants[msg["Site-Id"]][msg["Parent-Sku"]] = { variants = {} }
      for _, v in ipairs(msg.Variants) do
        if not v.sku or not v.attrs then
          return codec.error("INVALID_INPUT", "Variant requires sku and attrs", { variant = v })
        end
        local payload_len = validation.estimate_json_length(v)
        local ok_size, err_size = validation.check_size(payload_len, MAX_PAYLOAD_BYTES, "Variant")
        if not ok_size then
          return codec.error("INVALID_INPUT", err_size, { field = "Variants" })
        end
        table.insert(state.variants[msg["Site-Id"]][msg["Parent-Sku"]].variants, v)
      end
      audit.record(
        "catalog",
        "UpsertVariants",
        msg,
        nil,
        { parent = msg["Parent-Sku"], count = #msg.Variants }
      )
      return codec.ok {
        parentSku = msg["Parent-Sku"],
        variants = state.variants[msg["Site-Id"]][msg["Parent-Sku"]],
      }
    end
    
    function handlers.UpsertCategory(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Category-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Category-Id",
        "Payload",
        "Products",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_cat, err_cat = validation.check_length(msg["Category-Id"], 128, "Category-Id")
      if not ok_len_cat then
        return codec.error("INVALID_INPUT", err_cat, { field = "Category-Id" })
      end
      if msg.Payload then
        local ok_type_payload, err_type_payload =
          validation.assert_type(msg.Payload, "table", "Payload")
        if not ok_type_payload then
          return codec.error("INVALID_INPUT", err_type_payload, { field = "Payload" })
        end
      end
      if msg.Products then
        local ok_type_products, err_type_products =
          validation.assert_type(msg.Products, "table", "Products")
        if not ok_type_products then
          return codec.error("INVALID_INPUT", err_type_products, { field = "Products" })
        end
      end
      local payload_len = validation.estimate_json_length(msg.Payload or {})
      local ok_size, err_size = validation.check_size(payload_len, MAX_PAYLOAD_BYTES, "Payload")
      if not ok_size then
        return codec.error("INVALID_INPUT", err_size, { field = "Payload" })
      end
      local key = ids.category_key(msg["Site-Id"], msg["Category-Id"])
      state.categories[key] = {
        payload = msg.Payload or {},
        products = msg.Products or state.categories[key] and state.categories[key].products or {},
        updatedAt = os.time(),
      }
      purge_cache {
        paths = {
          "/c/" .. msg["Category-Id"],
          "/api/catalog/category/" .. msg["Category-Id"],
        },
        keys = { "category:" .. msg["Category-Id"] },
      }
      return codec.ok { categoryId = msg["Category-Id"] }
    end
    
    function handlers.DeleteCategory(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Category-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Category-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_cat, err_cat = validation.check_length(msg["Category-Id"], 128, "Category-Id")
      if not ok_len_cat then
        return codec.error("INVALID_INPUT", err_cat, { field = "Category-Id" })
      end
      local key = ids.category_key(msg["Site-Id"], msg["Category-Id"])
      state.categories[key] = nil
      state.category_deletions[msg["Site-Id"]] = state.category_deletions[msg["Site-Id"]] or {}
      table.insert(state.category_deletions[msg["Site-Id"]], { key = key, deletedAt = os.time() })
      audit.record("catalog", "DeleteCategory", msg, nil, { categoryId = msg["Category-Id"] })
      purge_cache {
        paths = {
          "/c/" .. msg["Category-Id"],
          "/api/catalog/category/" .. msg["Category-Id"],
        },
        keys = { "category:" .. msg["Category-Id"] },
      }
      return codec.ok { deleted = msg["Category-Id"] }
    end
    
    function handlers.GetCategory(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Category-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Category-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local key = ids.category_key(msg["Site-Id"], msg["Category-Id"])
      local cat = state.categories[key]
      if not cat then
        return codec.error("NOT_FOUND", "Category not found", { categoryId = msg["Category-Id"] })
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        categoryId = msg["Category-Id"],
        payload = cat.payload,
        products = cat.products,
        updatedAt = cat.updatedAt,
      }
    end
    
    function handlers.ListCategories(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Cursor",
        "Limit",
        "UpdatedAfter",
        "IncludeDeleted",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site = msg["Site-Id"]
      local updated_after = tonumber(msg.UpdatedAfter) or 0
      local cursor = msg.Cursor or ""
      local limit = tonumber(msg.Limit) or 200
      if limit < 1 then
        limit = 1
      end
      if limit > 500 then
        limit = 500
      end
      local prefix = "category:" .. site .. ":"
      local keys = {}
      for key, cat in pairs(state.categories) do
        if key:sub(1, #prefix) == prefix and (cat.updatedAt or 0) >= updated_after then
          table.insert(keys, key)
        end
      end
      table.sort(keys)
      local start_index = 1
      if cursor ~= "" then
        for i, k in ipairs(keys) do
          if k == cursor then
            start_index = i + 1
            break
          end
        end
      end
      local items = {}
      for i = start_index, math.min(#keys, start_index + limit - 1) do
        local key = keys[i]
        local cat = state.categories[key]
        table.insert(items, {
          key = key,
          categoryId = key:match "category:[^:]+:(.+)",
          payload = cat.payload,
          products = cat.products,
          updatedAt = cat.updatedAt,
        })
      end
      if msg.IncludeDeleted and state.category_deletions[site] then
        for _, d in ipairs(state.category_deletions[site]) do
          if (d.deletedAt or 0) >= updated_after then
            table.insert(items, { key = d.key, deletedAt = d.deletedAt, deleted = true })
          end
        end
      end
      local next_cursor = (#keys > start_index + limit - 1) and keys[start_index + limit - 1] or nil
      return codec.ok { siteId = site, items = items, nextCursor = next_cursor, total = #items }
    end
    
    function handlers.PublishCatalogVersion(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Version" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Version",
        "ExpectedVersion",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_site, err_site = validation.check_length(msg["Site-Id"], 128, "Site-Id")
      if not ok_len_site then
        return codec.error("INVALID_INPUT", err_site, { field = "Site-Id" })
      end
      local ok_len_ver, err_ver = validation.check_length(msg.Version, 128, "Version")
      if not ok_len_ver then
        return codec.error("INVALID_INPUT", err_ver, { field = "Version" })
      end
      if msg.ExpectedVersion then
        local ok_len_exp, err_exp = validation.check_length(msg.ExpectedVersion, 128, "ExpectedVersion")
        if not ok_len_exp then
          return codec.error("INVALID_INPUT", err_exp, { field = "ExpectedVersion" })
        end
      end
      local current = state.active_versions[msg["Site-Id"]]
      if msg.ExpectedVersion and current and current ~= msg.ExpectedVersion then
        return codec.error(
          "VERSION_CONFLICT",
          "ExpectedVersion mismatch",
          { expected = msg.ExpectedVersion, current = current }
        )
      end
      state.active_versions[msg["Site-Id"]] = msg.Version
      local resp = codec.ok { siteId = msg["Site-Id"], activeVersion = msg.Version }
      audit.record("catalog", "PublishCatalogVersion", msg, resp)
      return resp
    end
    
    -- Price lists per currency ------------------------------------------------
    function handlers.SetPriceList(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Currency", "Prices" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Currency",
        "Prices",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local currency = msg.Currency:upper()
      if not currency:match "^[A-Z][A-Z][A-Z]$" then
        return codec.error("INVALID_INPUT", "Currency must be ISO 4217 code", { field = "Currency" })
      end
      local ok_type, err_type = validation.assert_type(msg.Prices, "table", "Prices")
      if not ok_type then
        return codec.error("INVALID_INPUT", err_type, { field = "Prices" })
      end
      local window = {
        region = msg.Region,
        valid_from = msg.ValidFrom,
        valid_to = msg.ValidTo,
        prices = msg.Prices,
      }
      add_price_window(msg["Site-Id"], currency, window)
      audit.record(
        "catalog",
        "SetPriceList",
        msg,
        nil,
        { siteId = msg["Site-Id"], currency = currency, region = msg.Region }
      )
      return codec.ok { siteId = msg["Site-Id"], currency = currency, count = #msg.Prices }
    end
    
    -- Promos ------------------------------------------------------------------
    function handlers.AddPromo(msg)
      local ok, missing = validation.require_fields(msg, { "Code", "Type", "Value" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Code",
        "Type",
        "Value",
        "Skus",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local typ = msg.Type
      if typ ~= "percent" and typ ~= "amount" then
        return codec.error("INVALID_INPUT", "Type must be percent|amount", { field = "Type" })
      end
      local value = tonumber(msg.Value)
      if not value or value <= 0 then
        return codec.error("INVALID_INPUT", "Value must be positive number", { field = "Value" })
      end
      local skus = msg.Skus or {}
      state.promos[msg.Code] = { type = typ, value = value, skus = skus }
      audit.record("catalog", "AddPromo", msg, nil, { code = msg.Code, type = typ })
      return codec.ok { code = msg.Code, type = typ, value = value }
    end
    
    function handlers.UpsertPriceList(msg)
      return handlers.SetPriceList(msg)
    end
    
    function handlers.ApplyCoupon(msg)
      local ok, missing = validation.require_fields(msg, { "Code" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Code",
        "Type",
        "Value",
        "Applies-To",
        "FreeShipping",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local typ = msg.Type or "percent"
      local value = tonumber(msg.Value or 0) or 0
      state.coupons[msg.Code] = {
        type = typ,
        value = value,
        applies_to = msg["Applies-To"],
        free_shipping = msg.FreeShipping == true,
      }
      audit.record("catalog", "ApplyCoupon", msg, nil, { code = msg.Code, type = typ })
      return codec.ok { code = msg.Code, type = typ, freeShipping = msg.FreeShipping }
    end
    
    local function price_match_region(window_region, target_region)
      if not window_region or window_region == "" then
        return true
      end
      if not target_region or target_region == "" then
        return false
      end
      return window_region:upper() == target_region:upper()
    end
    
    local EU_COUNTRIES = {
      AT = true,
      BE = true,
      BG = true,
      CY = true,
      CZ = true,
      DE = true,
      DK = true,
      EE = true,
      ES = true,
      FI = true,
      FR = true,
      GR = true,
      HR = true,
      HU = true,
      IE = true,
      IT = true,
      LT = true,
      LU = true,
      LV = true,
      MT = true,
      NL = true,
      PL = true,
      PT = true,
      RO = true,
      SE = true,
      SI = true,
      SK = true,
    }
    
    local function is_eu(country)
      if not country then
        return false
      end
      return EU_COUNTRIES[country:upper()] == true
    end
    
    local function is_vat_id_valid(id)
      if not id or id == "" then
        return false
      end
      -- basic check: country prefix + 8-12 alnum
      return id:match "^[A-Z]{2}[A-Z0-9]{8,12}$" ~= nil
    end
    
    local function select_price(site_id, sku, currency, region)
      local now = os.time()
      local windows = state.price_windows[site_id]
      if windows and windows[currency] then
        local best = nil
        for _, w in ipairs(windows[currency]) do
          if price_match_region(w.region, region) then
            local vf = w.valid_from
              and validation.parse_iso8601
              and validation.parse_iso8601(w.valid_from)
            local vt = w.valid_to and validation.parse_iso8601 and validation.parse_iso8601(w.valid_to)
            local ok_time = true
            if vf and now < vf then
              ok_time = false
            end
            if vt and now > vt then
              ok_time = false
            end
            if ok_time and w.prices and w.prices[sku] then
              best = w.prices[sku]
              break
            end
          end
        end
        if best then
          return best, currency
        end
      end
      local pl = state.price_lists[site_id]
      if pl and pl[currency] and pl[currency][sku] then
        return pl[currency][sku], currency
      end
    end
    
    local function apply_pricing(site_id, sku, currency, promo_code, region)
      local product_key = ids.product_key(site_id, sku)
      local product = state.products[product_key]
      if not product then
        return nil, "NOT_FOUND"
      end
      local price = product.payload.price
      local base_currency = product.payload.currency or currency
      local override, o_cur = select_price(site_id, sku, currency, region)
      if override then
        price = override
        base_currency = o_cur
      end
      local free_shipping = false
      local bogo = false
      if promo_code then
        local coupon = state.coupons[promo_code]
        if coupon then
          local applies = not coupon.applies_to or #coupon.applies_to == 0
          if coupon.applies_to then
            for _, s in ipairs(coupon.applies_to) do
              if s == sku then
                applies = true
                break
              end
            end
          end
          if applies then
            if coupon.type == "percent" then
              price = price * (1 - coupon.value / 100)
            elseif coupon.type == "amount" then
              price = math.max(0, price - coupon.value)
            elseif coupon.type == "bogo" then
              bogo = true
            end
            if coupon.free_shipping then
              free_shipping = true
            end
          end
        end
        local promo = state.promos[promo_code]
        if promo then
          local applies = #promo.skus == 0
          if not applies then
            for _, s in ipairs(promo.skus) do
              if s == sku then
                applies = true
                break
              end
            end
          end
          if applies then
            if promo.type == "percent" then
              price = price * (1 - promo.value / 100)
            elseif promo.type == "amount" then
              price = math.max(0, price - promo.value)
            end
          end
        end
      end
      return { price = price, currency = base_currency, free_shipping = free_shipping, bogo = bogo },
        nil
    end
    
    function handlers.QuotePrice(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Sku",
        "Currency",
        "Promo",
        "Region",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local currency = msg.Currency or "USD"
      local quote = apply_pricing(msg["Site-Id"], msg.Sku, currency, msg.Promo, msg.Region)
      if not quote then
        return codec.error("NOT_FOUND", "Product not found", { sku = msg.Sku })
      end
      return codec.ok {
        sku = msg.Sku,
        price = quote.price,
        currency = quote.currency,
        promo = msg.Promo,
        region = msg.Region,
      }
    end
    
    -- Tax & shipping rules ----------------------------------------------------
    function handlers.SetTaxRules(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Rules" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Rules", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_type, err_type = validation.assert_type(msg.Rules, "table", "Rules")
      if not ok_type then
        return codec.error("INVALID_INPUT", err_type, { field = "Rules" })
      end
      for _, r in ipairs(msg.Rules) do
        if r.taxClass and type(r.taxClass) ~= "string" then
          return codec.error("INVALID_INPUT", "taxClass must be string", { rule = r })
        end
        if r.taxClass and #r.taxClass > 64 then
          return codec.error("INVALID_INPUT", "taxClass too long", { rule = r })
        end
        if r.taxInclusive ~= nil and type(r.taxInclusive) ~= "boolean" then
          return codec.error("INVALID_INPUT", "taxInclusive must be boolean", { rule = r })
        end
        if r.shippingTaxable ~= nil and type(r.shippingTaxable) ~= "boolean" then
          return codec.error("INVALID_INPUT", "shippingTaxable must be boolean", { rule = r })
        end
        if r.priority and type(r.priority) ~= "number" then
          return codec.error("INVALID_INPUT", "priority must be number", { rule = r })
        end
        if r.rate and (type(r.rate) ~= "number" or r.rate < 0 or r.rate > 100) then
          return codec.error("INVALID_INPUT", "rate must be 0-100 percent", { rule = r })
        end
        if r.Rate and (type(r.Rate) ~= "number" or r.Rate < 0 or r.Rate > 100) then
          return codec.error("INVALID_INPUT", "Rate must be 0-100 percent", { rule = r })
        end
        if r.country and (type(r.country) ~= "string" or #r.country ~= 2) then
          return codec.error("INVALID_INPUT", "country must be ISO2", { rule = r })
        end
        if r.region and type(r.region) ~= "string" then
          return codec.error("INVALID_INPUT", "region must be string", { rule = r })
        end
        if r.zipPrefix and type(r.zipPrefix) ~= "string" then
          return codec.error("INVALID_INPUT", "zipPrefix must be string", { rule = r })
        end
        if (r.zipFrom or r.zipTo) and (type(r.zipFrom) ~= "number" or type(r.zipTo) ~= "number") then
          return codec.error("INVALID_INPUT", "zipFrom/zipTo must be number", { rule = r })
        end
      end
      state.tax_rules[msg["Site-Id"]] = msg.Rules
      audit.record("catalog", "SetTaxRules", msg, nil, { siteId = msg["Site-Id"], count = #msg.Rules })
      return codec.ok { siteId = msg["Site-Id"], count = #msg.Rules }
    end
    
    function handlers.SetShippingRules(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Rules" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Rules", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_type, err_type = validation.assert_type(msg.Rules, "table", "Rules")
      if not ok_type then
        return codec.error("INVALID_INPUT", err_type, { field = "Rules" })
      end
      state.shipping_rules[msg["Site-Id"]] = msg.Rules
      audit.record(
        "catalog",
        "SetShippingRules",
        msg,
        nil,
        { siteId = msg["Site-Id"], count = #msg.Rules }
      )
      return codec.ok { siteId = msg["Site-Id"], count = #msg.Rules }
    end
    
    local function pick_tax_rule(site_id, address, tax_class)
      local rules = state.tax_rules[site_id] or state.tax_rates[site_id] or {}
      local best_rule = nil
      local best_score = -1
      for _, r in ipairs(rules) do
        local match = (not r.country or r.country == address.Country)
          and (not r.region or r.region == address.Region)
          and (not r.taxClass or r.taxClass == tax_class)
        if match and r.zipPrefix and address.PostalCode then
          match = address.PostalCode:sub(1, #r.zipPrefix) == r.zipPrefix
        end
        if match and r.zipFrom and r.zipTo and address.PostalCode then
          local z = tonumber(address.PostalCode:match "%d+")
          local zf, zt = tonumber(r.zipFrom), tonumber(r.zipTo)
          if z and zf and zt then
            match = z >= zf and z <= zt
          end
        end
        if match then
          local priority = tonumber(r.priority or r.Priority) or 0
          local specificity = (r.country and 1 or 0) + (r.region and 1 or 0) + (r.taxClass and 1 or 0)
          local score = priority * 10 + specificity
          if score > best_score then
            best_score = score
            best_rule = r
          end
        end
      end
      return best_rule, best_rule and (tonumber(best_rule.rate or best_rule.Rate) or 0) or 0
    end
    
    local function pick_tax_rate(site_id, address, tax_class)
      local _, rate = pick_tax_rule(site_id, address, tax_class)
      return rate
    end
    
    local function pick_shipping(site_id, address, total, weight, dims, opts)
      opts = opts or {}
      local rules = state.shipping_rules[site_id] or state.shipping_rates[site_id] or {}
      local billable_weight = weight or 0
      if dims and dims.length and dims.width and dims.height then
        billable_weight =
          math.max(weight or 0, dimensional_weight(dims.length, dims.width, dims.height, 5000))
      end
      local best = nil
      for _, r in ipairs(rules) do
        if
          (not r.country or r.country == address.Country)
          and (not r.region or r.region == address.Region)
          and (not r.min_total or total >= r.min_total)
          and (not r.max_total or total <= r.max_total)
          and (not r.min_weight or billable_weight >= r.min_weight)
          and (not r.max_weight or billable_weight <= r.max_weight)
        then
          if not best or (r.rate or 0) < (best.rate or 0) then
            best = r
          end
        end
      end
      local chosen = best or { rate = 0, carrier = "standard", service = "ground" }
      if opts.free_shipping then
        chosen.rate = 0
        chosen.service = "free"
      end
      return chosen
    end
    
    local function dimensional_weight(l, w, h, divisor)
      if not l or not w or not h then
        return 0
      end
      return (l * w * h) / (divisor or 5000)
    end
    
    local function shop_shipping(site_id, address, total, weight, dims)
      local rules = state.shipping_rules[site_id] or state.shipping_rates[site_id] or {}
      local billable_weight = weight or 0
      if dims and dims.length and dims.width and dims.height then
        billable_weight =
          math.max(weight or 0, dimensional_weight(dims.length, dims.width, dims.height, 5000))
      end
      local options = {}
      for _, r in ipairs(rules) do
        if
          (not r.country or r.country == address.Country)
          and (not r.region or r.region == address.Region)
          and (not r.min_total or total >= r.min_total)
          and (not r.max_total or total <= r.max_total)
          and (not r.min_weight or billable_weight >= r.min_weight)
          and (not r.max_weight or billable_weight <= r.max_weight)
        then
          table.insert(options, {
            carrier = r.carrier or "standard",
            service = r.service or "ground",
            rate = r.rate or 0,
            transitDays = r.transit_days or r.transitDays,
            currency = r.currency or "USD",
          })
        end
      end
      table.sort(options, function(a, b)
        return (a.rate or 0) < (b.rate or 0)
      end)
      while #options > MAX_RATE_OPTIONS do
        table.remove(options)
      end
      if CARRIER_API_URL and CARRIER_API_URL ~= "" then
        local payload = {
          siteId = site_id,
          address = address,
          total = total,
          weight = weight,
          currency = address.Currency or "USD",
        }
        local out = http_post_json(CARRIER_API_URL .. "/rates", payload)
        if out and out ~= "" then
          local ok, arr = pcall(cjson.decode, out)
          if ok and type(arr) == "table" then
            for _, o in ipairs(arr) do
              if o.rate then
                table.insert(options, {
                  carrier = o.carrier or "external",
                  service = o.service or "standard",
                  rate = o.rate,
                  transitDays = o.transitDays,
                  currency = o.currency or payload.currency,
                })
              end
            end
          end
        end
      end
      if #options == 0 then
        table.insert(options, { carrier = "standard", service = "ground", rate = 0, currency = "USD" })
      end
      return options
    end
    
    local function compute_cart(site_id, items, currency, promo)
      local subtotal = 0
      local weight = 0
      local lines = {}
      local free_shipping = false
      for _, it in ipairs(items) do
        local qty = tonumber(it.Qty or it.qty) or 0
        if qty <= 0 then
          return nil, "INVALID_QTY"
        end
        local sku = it.Sku or it.sku
        local quote, err = apply_pricing(site_id, sku, currency, promo, it.Region)
        if not quote then
          return nil, err or "NOT_FOUND"
        end
        if quote.free_shipping then
          free_shipping = true
        end
        local free_units = quote.bogo and math.floor(qty / 2) or 0
        local charge_qty = qty - free_units
        local line_total = quote.price * charge_qty
        subtotal = subtotal + line_total
        local pkey = ids.product_key(site_id, sku)
        local payload = state.products[pkey] and state.products[pkey].payload or {}
        weight = weight + (payload.weight or payload.Weight or 0) * qty
        table.insert(lines, {
          sku = sku,
          qty = qty,
          free_units = free_units,
          unit_price = quote.price,
          currency = quote.currency,
          line_total = line_total,
          taxClass = payload.taxClass or payload.TaxClass,
          taxInclusive = payload.taxInclusive or payload.TaxInclusive,
        })
      end
      return { subtotal = subtotal, weight = weight, lines = lines, free_shipping = free_shipping }, nil
    end
    
    function handlers.QuoteOrder(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Items", "Address" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Items",
        "Address",
        "Currency",
        "Promo",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_type_items, err_items = validation.assert_type(msg.Items, "table", "Items")
      if not ok_type_items or #msg.Items == 0 then
        return codec.error(
          "INVALID_INPUT",
          err_items or "Items must be non-empty array",
          { field = "Items" }
        )
      end
      local address = msg.Address
      if type(address) ~= "table" or not address.Country then
        return codec.error("INVALID_INPUT", "Address.Country required", { field = "Address" })
      end
      local currency = msg.Currency or "USD"
      local cart, cart_err = compute_cart(msg["Site-Id"], msg.Items, currency, msg.Promo)
      if not cart then
        return codec.error("INVALID_INPUT", cart_err or "Pricing failed")
      end
      -- inventory check across warehouses
      for _, line in ipairs(cart.lines) do
        local inv = state.inventory[msg["Site-Id"]] or {}
        local available = 0
        for _, wh in pairs(inv) do
          available = available + (wh[line.sku] or 0)
        end
        if available < line.qty then
          return codec.error(
            "OUT_OF_STOCK",
            "Insufficient inventory",
            { sku = line.sku, available = available }
          )
        end
      end
      local ship = pick_shipping(msg["Site-Id"], address, cart.subtotal, cart.weight)
      local tax, line_taxes, subtotal_ex, ship_tax, reverse_charge =
        calculate_tax_breakdown(msg["Site-Id"], address, cart, ship.rate)
      local total = subtotal_ex + ship.rate + ship_tax + tax
      return codec.ok {
        siteId = msg["Site-Id"],
        currency = currency,
        items = cart.lines,
        subtotal = cart.subtotal,
        subtotalExcl = subtotal_ex,
        weight = cart.weight,
        shipping = ship,
        tax = tax,
        shippingTax = ship_tax,
        lineTaxes = line_taxes,
        total = total,
        promo = msg.Promo,
        reverseCharge = reverse_charge,
      }
    end
    
    function handlers.CalculateTax(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Items", "Address" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Items",
        "Address",
        "Currency",
        "Promo",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local address = msg.Address
      if type(address) ~= "table" or not address.Country then
        return codec.error("INVALID_INPUT", "Address.Country required", { field = "Address" })
      end
      local currency = msg.Currency or "USD"
      local cart, cart_err = compute_cart(msg["Site-Id"], msg.Items, currency, msg.Promo)
      if not cart then
        return codec.error("INVALID_INPUT", cart_err or "Pricing failed")
      end
      local shipping = pick_shipping(msg["Site-Id"], address, cart.subtotal, cart.weight)
      local tax, line_taxes, subtotal_ex, ship_tax, reverse_charge =
        calculate_tax_breakdown(msg["Site-Id"], address, cart, shipping.rate)
      return codec.ok {
        siteId = msg["Site-Id"],
        subtotal = cart.subtotal,
        subtotalExcl = subtotal_ex,
        tax = tax,
        shippingTax = ship_tax,
        lineTaxes = line_taxes,
        shipping = shipping,
        total = subtotal_ex + shipping.rate + ship_tax + tax,
        currency = currency,
        reverseCharge = reverse_charge,
      }
    end
    
    function handlers.RateShopCarriers(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Items", "Address" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Items",
        "Address",
        "Currency",
        "Promo",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local address = msg.Address
      if type(address) ~= "table" or not address.Country then
        return codec.error("INVALID_INPUT", "Address.Country required", { field = "Address" })
      end
      local currency = msg.Currency or "USD"
      local cart, cart_err = compute_cart(msg["Site-Id"], msg.Items, currency, msg.Promo)
      if not cart then
        return codec.error("INVALID_INPUT", cart_err or "Pricing failed")
      end
      local dims = nil
      if msg.Dimensions then
        dims = {
          length = tonumber(msg.Dimensions.Length),
          width = tonumber(msg.Dimensions.Width),
          height = tonumber(msg.Dimensions.Height),
        }
      end
      local options = shop_shipping(msg["Site-Id"], address, cart.subtotal, cart.weight, dims)
      return codec.ok {
        siteId = msg["Site-Id"],
        subtotal = cart.subtotal,
        weight = cart.weight,
        currency = currency,
        options = options,
      }
    end
    
    -- Inventory per warehouse -------------------------------------------------
    function handlers.SetInventory(msg)
      local ok, missing =
        validation.require_fields(msg, { "Site-Id", "Warehouse-Id", "Sku", "Quantity" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Warehouse-Id",
        "Sku",
        "Quantity",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local qty = tonumber(msg.Quantity)
      if not qty or qty < 0 then
        return codec.error("INVALID_INPUT", "Quantity must be >= 0", { field = "Quantity" })
      end
      state.inventory[msg["Site-Id"]] = state.inventory[msg["Site-Id"]] or {}
      state.inventory[msg["Site-Id"]][msg["Warehouse-Id"]] = state.inventory[msg["Site-Id"]][msg["Warehouse-Id"]]
        or {}
      state.inventory[msg["Site-Id"]][msg["Warehouse-Id"]][msg.Sku] = qty
      -- compute total for alerts
      local total = 0
      for _, skus in pairs(state.inventory[msg["Site-Id"]]) do
        total = total + (skus[msg.Sku] or 0)
      end
      local policy = state.stock_policies[msg["Site-Id"]]
          and state.stock_policies[msg["Site-Id"]][msg.Sku]
        or {}
      push_low_stock(msg["Site-Id"], msg.Sku, total, policy.low_stock_threshold)
      audit.record(
        "catalog",
        "SetInventory",
        msg,
        nil,
        { siteId = msg["Site-Id"], warehouse = msg["Warehouse-Id"], sku = msg.Sku, quantity = qty }
      )
      return codec.ok {
        siteId = msg["Site-Id"],
        warehouse = msg["Warehouse-Id"],
        sku = msg.Sku,
        quantity = qty,
      }
    end
    
    function handlers.GetInventory(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Sku" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Sku", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local inv = state.inventory[msg["Site-Id"]] or {}
      local warehouses = {}
      local total = 0
      for wh, skus in pairs(inv) do
        local q = skus[msg.Sku] or 0
        if q > 0 then
          warehouses[wh] = q
          total = total + q
        end
      end
      local policy = state.stock_policies[msg["Site-Id"]]
        and state.stock_policies[msg["Site-Id"]][msg.Sku]
      return codec.ok {
        siteId = msg["Site-Id"],
        sku = msg.Sku,
        total = total,
        warehouses = warehouses,
        policy = policy,
      }
    end
    
    -- Stock policy (backorder/preorder thresholds) ----------------------------
    function handlers.SetStockPolicy(msg)
      local ok, missing =
        validation.require_fields(msg, { "Site-Id", "Sku", "Allow-Backorder", "Low-Stock-Threshold" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Sku",
        "Allow-Backorder",
        "Preorder-At",
        "ETA-Days",
        "Low-Stock-Threshold",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local allow_backorder = msg["Allow-Backorder"] == true or msg["Allow-Backorder"] == "true"
      local threshold = tonumber(msg["Low-Stock-Threshold"]) or 0
      if threshold < 0 then
        return codec.error(
          "INVALID_INPUT",
          "Low-Stock-Threshold must be >=0",
          { field = "Low-Stock-Threshold" }
        )
      end
      local preorder_at = msg["Preorder-At"]
      if preorder_at and type(preorder_at) ~= "string" then
        return codec.error(
          "INVALID_INPUT",
          "Preorder-At must be ISO date string",
          { field = "Preorder-At" }
        )
      end
      local eta_days = msg["ETA-Days"] and tonumber(msg["ETA-Days"]) or nil
      if eta_days and eta_days < 0 then
        return codec.error("INVALID_INPUT", "ETA-Days must be >=0", { field = "ETA-Days" })
      end
      state.stock_policies[msg["Site-Id"]] = state.stock_policies[msg["Site-Id"]] or {}
      state.stock_policies[msg["Site-Id"]][msg.Sku] = {
        allow_backorder = allow_backorder,
        preorder_at = preorder_at,
        low_stock_threshold = threshold,
        eta_days = eta_days,
      }
      audit.record(
        "catalog",
        "SetStockPolicy",
        msg,
        nil,
        { sku = msg.Sku, allow_backorder = allow_backorder, threshold = threshold }
      )
      return codec.ok {
        siteId = msg["Site-Id"],
        sku = msg.Sku,
        allowBackorder = allow_backorder,
        preorderAt = preorder_at,
        lowStockThreshold = threshold,
        etaDays = eta_days,
      }
    end
    
    local function push_low_stock(site_id, sku, total, threshold)
      if threshold and threshold > 0 and total <= threshold then
        state.stock_alerts[site_id] = state.stock_alerts[site_id] or {}
        local alert = {
          sku = sku,
          total = total,
          threshold = threshold,
          ts = os.time(),
        }
        table.insert(state.stock_alerts[site_id], alert)
        deliver_stock_alert(site_id, alert)
      end
    end
    
    local function record_backorder(site_id, sku, qty, source, ref, preorder_at, eta_days)
      state.backorders[site_id] = state.backorders[site_id] or {}
      table.insert(state.backorders[site_id], {
        sku = sku,
        qty = qty,
        source = source,
        ref = ref,
        preorder_at = preorder_at,
        eta_days = eta_days,
        createdAt = os.time(),
      })
    end
    
    function handlers.ListLowStock(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Clear", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local alerts = state.stock_alerts[msg["Site-Id"]] or {}
      local clear = msg.Clear == true or msg.Clear == "true"
      if clear then
        state.stock_alerts[msg["Site-Id"]] = {}
      end
      return codec.ok { siteId = msg["Site-Id"], alerts = alerts }
    end
    
    function handlers.DeliverLowStockAlerts(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local alerts = state.stock_alerts[msg["Site-Id"]] or {}
      for _, alert in ipairs(alerts) do
        deliver_stock_alert(msg["Site-Id"], alert)
      end
      return codec.ok { siteId = msg["Site-Id"], delivered = #alerts }
    end
    
    function handlers.ListBackorders(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Sku",
        "Source",
        "Cursor",
        "Limit",
        "Clear",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit) or 200
      if limit < 1 then
        limit = 1
      end
      if limit > 1000 then
        limit = 1000
      end
      local cursor = tonumber(msg.Cursor) or 0
      local out = {}
      local all = state.backorders[msg["Site-Id"]] or {}
      local filtered = {}
      for _, bo in ipairs(all) do
        if (not msg.Sku or msg.Sku == bo.sku) and (not msg.Source or msg.Source == bo.source) then
          table.insert(filtered, bo)
        end
      end
      table.sort(filtered, function(a, b)
        return (a.createdAt or 0) > (b.createdAt or 0)
      end)
      for i = cursor + 1, math.min(#filtered, cursor + limit) do
        table.insert(out, filtered[i])
      end
      local next_cursor = (#filtered > cursor + limit) and (cursor + limit) or nil
      if msg.Clear == true or msg.Clear == "true" then
        state.backorders[msg["Site-Id"]] = {}
      end
      return codec.ok {
        siteId = msg["Site-Id"],
        items = out,
        nextCursor = next_cursor,
        total = #out,
        filterSku = msg.Sku,
        filterSource = msg.Source,
      }
    end
    
    function handlers.ForgetSubject(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Subject" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Site-Id", "Subject", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local count = forget_subject(msg["Site-Id"], msg.Subject)
      if WORKER_FORGET_URL then
        local body = string.format('{"subject":"%s"}', msg.Subject)
        local cmd = string.format(
          "curl -sS -X POST %q -H 'Content-Type: application/json'%s -d %q >/dev/null 2>&1",
          WORKER_FORGET_URL,
          WORKER_AUTH_TOKEN and (" -H 'Authorization: Bearer " .. WORKER_AUTH_TOKEN .. "'") or "",
          body
        )
        os.execute(cmd)
      end
      audit.record(
        "catalog",
        "ForgetSubject",
        msg,
        nil,
        { siteId = msg["Site-Id"], subject = msg.Subject }
      )
      return codec.ok { siteId = msg["Site-Id"], subject = msg.Subject, scrubbed = count }
    end
    
    -- Checkout skeleton -------------------------------------------------------
    local function reserve_inventory(site_id, items)
      local inv = state.inventory[site_id] or {}
      local changes = {}
      local backorders = {}
      for _, item in ipairs(items) do
        local needed = item.qty
        for wh, skus in pairs(inv) do
          local available = skus[item.sku] or 0
          if available > 0 then
            local take = math.min(available, needed)
            skus[item.sku] = available - take
            needed = needed - take
            table.insert(changes, { warehouse = wh, sku = item.sku, qty = take })
            if needed == 0 then
              break
            end
          end
        end
        if needed > 0 then
          local policy = state.stock_policies[site_id] and state.stock_policies[site_id][item.sku] or {}
          if policy.allow_backorder then
            table.insert(backorders, {
              sku = item.sku,
              qty = needed,
              preorder_at = policy.preorder_at,
              eta_days = policy.eta_days,
            })
          else
            -- rollback
            for _, c in ipairs(changes) do
              inv[c.warehouse][c.sku] = (inv[c.warehouse][c.sku] or 0) + c.qty
            end
            return false, "INSUFFICIENT_STOCK"
          end
        end
        -- low stock alert after deduction
        local total_after = 0
        for _, skus in pairs(inv) do
          total_after = total_after + (skus[item.sku] or 0)
        end
        local policy = state.stock_policies[site_id] and state.stock_policies[site_id][item.sku] or {}
        push_low_stock(site_id, item.sku, total_after, policy.low_stock_threshold)
        if needed > 0 then
          record_backorder(
            site_id,
            item.sku,
            needed,
            "reserve",
            nil,
            policy.preorder_at,
            policy.eta_days
          )
        end
      end
      return true, changes, backorders
    end
    
    local function purge_cache(opts)
      opts = opts or {}
      local paths = opts.paths or opts
      local keys = opts.keys or {}
      if CDN_PURGE_CMD and CDN_PURGE_CMD ~= "" then
        for _, p in ipairs(paths or {}) do
          local cmd = string.format(CDN_PURGE_CMD, p)
          os.execute(cmd .. " >/dev/null 2>&1")
        end
      end
      if CDN_SURROGATE_CMD and CDN_SURROGATE_CMD ~= "" then
        for _, k in ipairs(keys) do
          local cmd = string.format(CDN_SURROGATE_CMD, k)
          os.execute(cmd .. " >/dev/null 2>&1")
        end
      end
    end
    
    local function parse_sizes(str)
      local sizes = {}
      for token in tostring(str or ""):gmatch "[^,]+" do
        local w, h = token:match "(%d+)x(%d+)"
        if w and h then
          table.insert(sizes, { tonumber(w), tonumber(h) })
        end
      end
      return sizes
    end
    
    local function parse_formats(str)
      local fmts = {}
      for token in tostring(str or ""):gmatch "[^,]+" do
        table.insert(fmts, token)
      end
      return fmts
    end
    
    local function parse_set(str)
      local out = {}
      for token in tostring(str or ""):gmatch "[^,; ]+" do
        out[token:upper()] = true
      end
      return out
    end
    
    local function add_price_window(site_id, currency, window)
      if not window or not currency or not site_id then
        return
      end
      state.price_windows[site_id] = state.price_windows[site_id] or {}
      state.price_windows[site_id][currency] = state.price_windows[site_id][currency] or {}
      table.insert(state.price_windows[site_id][currency], window)
    end
    
    local function ensure_dir(path)
      if not path or path == "" then
        return false
      end
      os.execute(string.format("mkdir -p '%s'", path))
      return true
    end
    
    local function fetch_file(src)
      if not src or src == "" then
        return nil, "missing_source"
      end
      if src:match "^https?://" then
        local tmp = os.tmpname()
        local cmd = string.format(
          "curl -sS --max-time %d --connect-timeout %d '%s' -o %s",
          HTTP_TIMEOUT,
          HTTP_CONNECT_TIMEOUT,
          src,
          tmp
        )
        local rc = os.execute(cmd)
        if rc == true or rc == 0 then
          return tmp, nil, true
        end
        os.remove(tmp)
        return nil, "download_failed"
      end
      -- local path
      local f = io.open(src, "rb")
      if not f then
        return nil, "source_not_found"
      end
      f:close()
      return src, nil, false
    end
    
    local function upload_image(path, relkey)
      if not IMAGE_S3_BUCKET or IMAGE_S3_BUCKET == "" then
        return nil
      end
      local prefix = IMAGE_S3_PREFIX
      if prefix ~= "" and not prefix:match "/$" then
        prefix = prefix .. "/"
      end
      local key = prefix .. relkey
      local cmd = string.format(
        "aws s3 cp %s s3://%s/%s --no-progress --cli-read-timeout %d --cli-connect-timeout %d",
        path,
        IMAGE_S3_BUCKET,
        key,
        S3_TIMEOUT,
        S3_TIMEOUT
      )
      local rc = os.execute(cmd)
      if rc == true or rc == 0 then
        if IMAGE_PUBLIC_BASE and IMAGE_PUBLIC_BASE ~= "" then
          local base = IMAGE_PUBLIC_BASE
          if base:sub(-1) == "/" then
            base = base:sub(1, -2)
          end
          return base .. "/" .. key
        end
        return "https://" .. IMAGE_S3_BUCKET .. ".s3.amazonaws.com/" .. key
      end
      return nil, "upload_failed"
    end
    
    local function resize_and_store(site_id, sku, src_path)
      if not IMAGE_RESIZE_CMD or not IMAGE_STORE_DIR or IMAGE_STORE_DIR == "" then
        return nil, "IMAGE_PIPELINE_DISABLED"
      end
      local local_path, ferr, tmp = fetch_file(src_path)
      if not local_path then
        return nil, ferr or "SOURCE_NOT_FOUND"
      end
      ensure_dir(IMAGE_STORE_DIR)
      local sizes = parse_sizes(IMAGE_SIZES)
      local fmts = parse_formats(IMAGE_FORMATS)
      local dests = {}
      for _, sz in ipairs(sizes) do
        local w, h = sz[1], sz[2]
        for _, fmt in ipairs(fmts) do
          local out_dir = string.format("%s/%s/%s", IMAGE_STORE_DIR, fmt, sku)
          ensure_dir(out_dir)
          local outfile = string.format("%s/%dx%d.%s", out_dir, w, h, fmt)
          local cmd = string.format(IMAGE_RESIZE_CMD, local_path, w, h, outfile)
          os.execute(cmd .. " >/dev/null 2>&1")
          local rel = outfile:gsub("^" .. IMAGE_STORE_DIR .. "/?", "")
          local url, up_err = upload_image(outfile, rel)
          table.insert(dests, {
            url = url or outfile,
            width = w,
            height = h,
            format = fmt,
            uploaded = up_err == nil,
          })
        end
      end
      state.assets[site_id] = state.assets[site_id] or {}
      state.assets[site_id][sku] = state.assets[site_id][sku] or {}
      state.assets[site_id][sku].variants = dests
      state.assets[site_id][sku].original = src_path
      -- purge cached variants
      local purge_list = { src_path }
      for _, d in ipairs(dests) do
        table.insert(purge_list, d.url)
      end
      purge_cache { paths = purge_list, keys = { "product:" .. sku, "images:" .. sku } }
      if tmp then
        os.remove(local_path)
      end
      return dests
    end
    
    local function forget_subject(site_id, subject)
      if not subject or subject == "" then
        return 0
      end
      local scrubbed = 0
      -- remove from recent list
      for sub in pairs(state.recent) do
        if sub == subject then
          state.recent[sub] = nil
          scrubbed = scrubbed + 1
        end
      end
      -- scrub checkouts
      for _, chk in pairs(state.checkouts) do
        if chk.siteId == site_id and chk.email == subject then
          chk.email = nil
          chk.address = nil
          scrubbed = scrubbed + 1
        end
      end
      -- scrub orders
      for _, ord in pairs(state.orders) do
        if ord.siteId == site_id and ord.email == subject then
          ord.email = nil
          ord.address = nil
          scrubbed = scrubbed + 1
        end
      end
      -- scrub telemetry buffered events
      if state.telemetry[site_id] then
        local filtered = {}
        for _, ev in ipairs(state.telemetry[site_id]) do
          if ev.subject ~= subject then
            table.insert(filtered, ev)
          end
        end
        state.telemetry[site_id] = filtered
      end
      -- scrub shipments linked to subject's orders
      for _, sh in pairs(state.shipments) do
        if sh.orderId and state.orders[sh.orderId] and state.orders[sh.orderId].email == subject then
          sh.address = nil
          scrubbed = scrubbed + 1
        end
      end
      -- scrub returns linked to subject's orders
      for _, ret in pairs(state.returns) do
        if ret.orderId and state.orders[ret.orderId] and state.orders[ret.orderId].email == subject then
          ret.address = nil
          ret.reason = nil
          scrubbed = scrubbed + 1
        end
      end
      return scrubbed
    end
    
    local function notify_rma(site_id, return_id, event, payload)
      if not RMA_WEBHOOK or RMA_WEBHOOK == "" or not json_ok then
        return
      end
      local body = {
        type = "rma." .. event,
        siteId = site_id,
        returnId = return_id,
        payload = payload,
      }
      local ok, json_body = pcall(cjson.encode, body)
      if not ok then
        return
      end
      local cmd = string.format(
        "curl -sS -m %d -H 'Content-Type: application/json' -d '%s' %s >/dev/null 2>&1",
        HTTP_TIMEOUT,
        json_body:gsub("'", "'\\''"),
        RMA_WEBHOOK
      )
      os.execute(cmd)
    end
    
    local function send_with_retry(site_id, target, body, kind)
      if not target or target == "" or not json_ok then
        return false, "target_missing"
      end
      local ok, json_body = pcall(cjson.encode, body)
      if not ok then
        return false, "encode_failed"
      end
      local safe = json_body:gsub("'", "'\\''")
      local attempts = 0
      local success = false
      local err = nil
      while attempts <= NOTIFY_RETRIES do
        attempts = attempts + 1
        local cmd = string.format(
          "curl -sS -m %d -H 'Content-Type: application/json' -d '%s' %s >/dev/null 2>&1",
          HTTP_TIMEOUT,
          safe,
          target
        )
        local rc = os.execute(cmd)
        success = (rc == true or rc == 0)
        if success then
          break
        end
        err = "curl_failed"
        if attempts <= NOTIFY_RETRIES then
          -- backoff
          os.execute(string.format("sleep %.3f", NOTIFY_BACKOFF_MS / 1000))
        end
      end
      if not success then
        state.notification_failures[site_id or "global"] = state.notification_failures[site_id or "global"]
          or {}
        table.insert(state.notification_failures[site_id or "global"], {
          type = kind,
          target = target,
          payload = body,
          attempts = attempts,
          ts = os.time(),
          error = err,
        })
      end
      return success, err
    end
    
    local function notify_customer(event, payload)
      return send_with_retry(
        payload.siteId,
        CUSTOMER_WEBHOOK,
        { type = event, payload = payload },
        event
      )
    end
    
    local function record_shipment_event(shipment_id, status, meta)
      state.shipment_events[shipment_id] = state.shipment_events[shipment_id] or {}
      table.insert(state.shipment_events[shipment_id], {
        ts = os.time(),
        status = status,
        meta = meta,
      })
    end
    
    local function cleanup_retention()
      local cutoff = os.time() - (RETENTION_DAYS * 86400)
      for site, evs in pairs(state.telemetry) do
        local filtered = {}
        for _, ev in ipairs(evs) do
          if not ev.ts or ev.ts >= cutoff then
            table.insert(filtered, ev)
          end
        end
        state.telemetry[site] = filtered
      end
      for site, log in pairs(state.event_log) do
        local filtered = {}
        for _, ev in ipairs(log) do
          if (ev.ts or 0) >= cutoff then
            table.insert(filtered, ev)
          end
        end
        state.event_log[site] = filtered
      end
      for site, alerts in pairs(state.stock_alerts) do
        local filtered = {}
        for _, a in ipairs(alerts) do
          if (a.ts or 0) >= cutoff then
            table.insert(filtered, a)
          end
        end
        state.stock_alerts[site] = filtered
      end
      for site, list in pairs(state.backorders) do
        local filtered = {}
        for _, bo in ipairs(list) do
          if (bo.createdAt or 0) >= cutoff then
            table.insert(filtered, bo)
          end
        end
        state.backorders[site] = filtered
      end
      for ship, events in pairs(state.shipment_events) do
        local filtered = {}
        for _, e in ipairs(events) do
          if (e.ts or 0) >= cutoff then
            table.insert(filtered, e)
          end
        end
        state.shipment_events[ship] = filtered
      end
      for site, fails in pairs(state.notification_failures) do
        local filtered = {}
        for _, f in ipairs(fails) do
          if (f.ts or 0) >= cutoff then
            table.insert(filtered, f)
          end
        end
        state.notification_failures[site] = filtered
      end
      -- delete old shipment event logs
      for ship, events in pairs(state.shipment_events) do
        local filtered = {}
        for _, e in ipairs(events) do
          if (e.ts or 0) >= cutoff then
            table.insert(filtered, e)
          end
        end
        state.shipment_events[ship] = filtered
      end
      for key, ts in pairs(state.webhook_seen) do
        if (ts or 0) < os.time() - WEBHOOK_REPLAY_WINDOW then
          state.webhook_seen[key] = nil
        end
      end
      for provider, events in pairs(state.provider_events) do
        local filtered = {}
        for id, ts in pairs(events) do
          if (ts or 0) >= cutoff then
            filtered[id] = ts
          end
        end
        state.provider_events[provider] = filtered
      end
      for idem_key, res in pairs(state.stripe_idempotency) do
        if
          res
          and res.nextAction
          and res.nextAction.expiresAt
          and res.nextAction.expiresAt < os.time()
        then
          state.stripe_idempotency[idem_key] = nil
        end
      end
      for _, pay in pairs(state.payments) do
        if
          pay.status == "requires_action"
          and pay.challengeExpiresAt
          and pay.challengeExpiresAt < os.time()
        then
          pay.status = "failed"
        end
      end
    end
    
    local function parse_csv_line(line)
      local res = {}
      local i = 1
      local in_quote = false
      local field = ""
      while i <= #line do
        local c = line:sub(i, i)
        if c == '"' then
          if in_quote and line:sub(i + 1, i + 1) == '"' then
            field = field .. '"'
            i = i + 1
          else
            in_quote = not in_quote
          end
        elseif c == "," and not in_quote then
          table.insert(res, field)
          field = ""
        else
          field = field .. c
        end
        i = i + 1
      end
      table.insert(res, field)
      return res
    end
    
    local function deliver_stock_alert(site_id, alert)
      if not STOCK_ALERT_WEBHOOK or STOCK_ALERT_WEBHOOK == "" or not json_ok then
        return
      end
      local body = {
        type = "low_stock",
        siteId = site_id,
        sku = alert.sku,
        total = alert.total,
        threshold = alert.threshold,
        ts = alert.ts,
      }
      send_with_retry(site_id, STOCK_ALERT_WEBHOOK, body, "low_stock")
    end
    
    function handlers.StartCheckout(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Items", "Address", "Email" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Items",
        "Address",
        "Email",
        "Currency",
        "Promo",
        "Payment-Method",
        "Require3DS",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local currency = msg.Currency or "USD"
      local cart, cart_err = compute_cart(msg["Site-Id"], msg.Items, currency, msg.Promo)
      if not cart then
        return codec.error("INVALID_INPUT", cart_err or "Pricing failed")
      end
      local address = msg.Address
      if type(address) ~= "table" or not address.Country then
        return codec.error("INVALID_INPUT", "Address.Country required", { field = "Address" })
      end
      local dims = nil
      if msg.Dimensions then
        dims = {
          length = tonumber(msg.Dimensions.Length),
          width = tonumber(msg.Dimensions.Width),
          height = tonumber(msg.Dimensions.Height),
        }
      end
      local shipping = pick_shipping(
        msg["Site-Id"],
        address,
        cart.subtotal,
        cart.weight,
        dims,
        { free_shipping = cart.free_shipping }
      )
      local tax, _, subtotal_ex, ship_tax =
        calculate_tax_breakdown(msg["Site-Id"], address, cart, shipping.rate)
      local total = subtotal_ex + shipping.rate + ship_tax + tax
      local items = {}
      for _, item in ipairs(msg.Items) do
        table.insert(items, { sku = item.Sku, qty = tonumber(item.Qty) or 0 })
      end
      local ok_reserve, changes, backorders = reserve_inventory(msg["Site-Id"], items)
      if not ok_reserve then
        return codec.error("OUT_OF_STOCK", "Insufficient inventory during reserve")
      end
      local checkout_id = string.format("chk-%d", os.time() * 1000 + math.random(0, 999))
      state.checkouts[checkout_id] = {
        siteId = msg["Site-Id"],
        items = items,
        address = msg.Address,
        email = msg.Email,
        quote = {
          subtotal = cart.subtotal,
          subtotalExcl = subtotal_ex,
          weight = cart.weight,
          tax = tax,
          shippingTax = ship_tax,
          shipping = shipping,
          total = total,
          currency = currency,
          promo = msg.Promo,
        },
        status = "pending_payment",
        reserve = changes,
        backorders = backorders,
        risk = risk_score {
          quote = {
            subtotal = cart.subtotal,
            shipping = shipping,
            total = total,
            promo = msg.Promo,
          },
          address = msg.Address,
          email = msg.Email,
        },
      }
      local payment
      if msg["Payment-Method"] then
        payment = create_payment_intent_internal {
          siteId = msg["Site-Id"],
          checkoutId = checkout_id,
          amount = total,
          currency = currency,
          method = msg["Payment-Method"],
          require3ds = msg.Require3DS,
        }
      end
      for _, bo in ipairs(backorders or {}) do
        record_backorder(
          msg["Site-Id"],
          bo.sku,
          bo.qty,
          "checkout",
          checkout_id,
          bo.preorder_at,
          bo.eta_days
        )
      end
      return codec.ok {
        checkoutId = checkout_id,
        total = total,
        currency = currency,
        tax = tax,
        taxRate = subtotal_ex > 0 and (tax * 100 / subtotal_ex) or 0,
        shipping = shipping,
        paymentIntent = payment and payment.paymentId,
        paymentStatus = payment and payment.status or "pending_payment",
        risk = state.checkouts[checkout_id].risk,
        backorders = backorders,
      }
    end
    
    function handlers.CompleteCheckout(msg)
      local ok, missing = validation.require_fields(msg, { "Checkout-Id", "Payment-Method" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Checkout-Id",
        "Payment-Method",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local chk = state.checkouts[msg["Checkout-Id"]]
      if not chk then
        return codec.error("NOT_FOUND", "Checkout not found", { checkoutId = msg["Checkout-Id"] })
      end
      if chk.status ~= "pending_payment" then
        return codec.error("INVALID_STATE", "Checkout already completed", { status = chk.status })
      end
      local payment_id = chk.paymentIntent
      if not payment_id then
        local created = create_payment_intent_internal {
          siteId = chk.siteId,
          checkoutId = msg["Checkout-Id"],
          amount = chk.quote.total,
          currency = chk.quote.currency or "USD",
          method = msg["Payment-Method"],
          require3ds = msg.Require3DS,
        }
        payment_id = created.paymentId
      end
      local pay = state.payments[payment_id]
      if not pay then
        return codec.error("NOT_FOUND", "Payment intent missing", { paymentId = payment_id })
      end
      if pay.requiresAction and not msg.ChallengeCompleted then
        return codec.error("REQUIRES_ACTION", "3DS challenge not completed")
      end
      if chk.risk and chk.risk >= RISK_THRESHOLD and not msg.OverrideRisk then
        chk.status = "manual_review"
        return codec.error("REVIEW_REQUIRED", "Checkout flagged for manual review", { risk = chk.risk })
      end
      pay.status = "captured"
      pay.capturedAt = os.time()
      chk.status = "paid"
      chk.payment = {
        method = msg["Payment-Method"],
        status = pay.status,
        paidAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
        paymentId = pay.paymentId,
      }
      audit.record("catalog", "CompleteCheckout", msg, nil, { checkoutId = msg["Checkout-Id"] })
      return codec.ok {
        checkoutId = msg["Checkout-Id"],
        status = chk.status,
        payment = chk.payment,
        risk = chk.risk,
      }
    end
    
    function handlers.Complete3DSChallenge(msg)
      local ok, missing = validation.require_fields(msg, { "Payment-Id", "Token" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Payment-Id",
        "Token",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local pay = state.payments[msg["Payment-Id"]]
      if not pay then
        return codec.error("NOT_FOUND", "Payment not found")
      end
      if pay.status ~= "requires_action" then
        return codec.error("INVALID_INPUT", "Payment not awaiting 3DS", { status = pay.status })
      end
      local expected = pay.challengeToken or ("3ds-" .. msg["Payment-Id"])
      if msg.Token ~= expected then
        return codec.error("FORBIDDEN", "Token mismatch")
      end
      if pay.challengeExpiresAt and os.time() > pay.challengeExpiresAt then
        return codec.error("FORBIDDEN", "3DS token expired")
      end
      pay.status = "captured"
      pay.capturedAt = os.time()
      audit.record("catalog", "Complete3DSChallenge", msg, nil, { paymentId = pay.paymentId })
      return codec.ok { paymentId = pay.paymentId, status = pay.status }
    end
    
    function handlers.CreatePaymentIntent(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Amount", "Currency", "Method" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Checkout-Id",
        "Order-Id",
        "Amount",
        "Currency",
        "Method",
        "Require3DS",
        "IdempotencyKey",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      if type(msg.Amount) ~= "number" or msg.Amount <= 0 then
        return codec.error("INVALID_INPUT", "Amount must be positive number")
      end
      if not msg.Currency or #msg.Currency ~= 3 then
        return codec.error("INVALID_INPUT", "Currency must be ISO 4217")
      end
      local method = msg.Method
      local allowed = { card = true, paypal = true, applepay = true, googlepay = true, ideal = true }
      if not allowed[method] then
        return codec.error("INVALID_INPUT", "Unsupported payment method")
      end
      if msg["Checkout-Id"] and not state.checkouts[msg["Checkout-Id"]] then
        return codec.error("NOT_FOUND", "Checkout not found", { checkoutId = msg["Checkout-Id"] })
      end
      if not check_rate_limit("pi:" .. (msg.Subject or msg["Site-Id"])) then
        return codec.error("RATE_LIMITED", "Too many payment attempts")
      end
      if msg["Order-Id"] and not state.orders[msg["Order-Id"]] then
        return codec.error("NOT_FOUND", "Order not found", { orderId = msg["Order-Id"] })
      end
      local provider = msg.Provider or "internal"
      if PSP_HOSTED_ONLY and provider ~= "internal" then
        return codec.error(
          "PSP_NOT_CONFIGURED",
          "Server-side PSP calls disabled; use hosted payment page",
          { provider = provider }
        )
      end
      local idem_key = msg.IdempotencyKey
      if provider == "stripe" and idem_key then
        local cached = state.stripe_idempotency[idem_key]
        if cached then
          return codec.ok(cached)
        end
      end
      local token = msg.Token
      if msg.Subject and not token and state.payment_tokens[msg.Subject] then
        local last = state.payment_tokens[msg.Subject][#state.payment_tokens[msg.Subject]]
        token = last and last.token
      end
      local record = create_payment_intent_internal {
        siteId = msg["Site-Id"],
        checkoutId = msg["Checkout-Id"],
        orderId = msg["Order-Id"],
        amount = msg.Amount,
        currency = msg.Currency,
        method = method,
        require3ds = msg.Require3DS,
        provider = provider,
        token = token,
        subject = msg.Subject,
      }
      if record.requiresAction then
        record.challengeToken = "3ds-" .. record.paymentId
        record.challengeExpiresAt = os.time() + CHALLENGE_TTL
        state.payments[record.paymentId].challengeToken = record.challengeToken
        state.payments[record.paymentId].challengeExpiresAt = record.challengeExpiresAt
      end
      audit.record(
        "catalog",
        "CreatePaymentIntent",
        msg,
        nil,
        { paymentId = record.paymentId, status = record.status }
      )
      metrics.inc "catalog.CreatePaymentIntent.count"
      metrics.tick()
      local resp = {
        paymentId = record.paymentId,
        status = record.status,
        provider = record.provider,
        clientSecret = record.clientSecret,
        nextAction = record.requiresAction and {
          type = "3ds_redirect",
          token = record.challengeToken,
          url = THREE_DS_URL .. "?pid=" .. record.paymentId .. "&token=" .. record.challengeToken,
          expiresAt = record.challengeExpiresAt,
        } or nil,
      }
      if provider == "stripe" and idem_key then
        state.stripe_idempotency[idem_key] = resp
      end
      return codec.ok(resp)
    end
    
    function handlers.TokenizePaymentMethod(msg)
      local ok, missing = validation.require_fields(msg, { "Provider", "Payload" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Subject",
        "Provider",
        "Payload",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      if type(msg.Payload) ~= "table" then
        return codec.error("INVALID_INPUT", "Payload must be object")
      end
      local provider = msg.Provider
      if PSP_HOSTED_ONLY then
        return codec.error(
          "PSP_NOT_CONFIGURED",
          "Server-side tokenization disabled; use hosted PSP tokens",
          { provider = provider }
        )
      end
      if
        provider ~= "stripe"
        and provider ~= "paypal"
        and provider ~= "adyen"
        and provider ~= "apple_pay"
        and provider ~= "google_pay"
      then
        return codec.error("INVALID_INPUT", "Unsupported provider")
      end
      local token = string.format("%s_tok_%s", provider, gen_id "pm")
      if msg.Subject then
        state.payment_tokens[msg.Subject] = state.payment_tokens[msg.Subject] or {}
        table.insert(state.payment_tokens[msg.Subject], {
          provider = provider,
          token = token,
          label = msg.Payload.label,
          last4 = msg.Payload.last4 or msg.Payload.Last4,
          brand = msg.Payload.brand,
          exp = msg.Payload.exp,
          default = msg.Payload.default == true,
        })
      end
      audit.record("catalog", "TokenizePaymentMethod", msg, nil, { provider = provider })
      return codec.ok { token = token, provider = provider }
    end
    
    function handlers.CapturePayment(msg)
      local ok, missing = validation.require_fields(msg, { "Payment-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Payment-Id",
        "ChallengeCompleted",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local pay = state.payments[msg["Payment-Id"]]
      if not pay then
        return codec.error("NOT_FOUND", "Payment not found")
      end
      if pay.status == "captured" or pay.status == "refunded" then
        return codec.ok { paymentId = pay.paymentId, status = pay.status }
      end
      if pay.requiresAction and not msg.ChallengeCompleted then
        return codec.error("REQUIRES_ACTION", "3DS challenge not completed")
      end
      if PSP_HOSTED_ONLY and pay.provider ~= "internal" then
        return codec.error(
          "PSP_NOT_CONFIGURED",
          "Server-side capture disabled; use hosted PSP",
          { provider = pay.provider }
        )
      end
      if pay.provider ~= "internal" then
        local ok_cap, resp = psp_call(
          pay.provider,
          "capture",
          { id = pay.providerPaymentId or pay.paymentId, amount = pay.amount }
        )
        if not ok_cap or (resp and resp.status ~= "captured") then
          return codec.error(
            "PROVIDER_ERROR",
            "Capture failed",
            { provider = pay.provider, reason = resp }
          )
        end
        pay.providerCaptureId = resp.providerCaptureId
      end
      pay.status = "captured"
      pay.capturedAt = os.time()
      table.insert(state.payment_attempts[pay.paymentId] or {}, {
        ts = os.time(),
        event = "captured",
        status = pay.status,
        provider = pay.provider,
      })
      if pay.orderId and state.orders[pay.orderId] then
        state.orders[pay.orderId].paymentStatus = "paid"
      end
      if pay.checkoutId and state.checkouts[pay.checkoutId] then
        state.checkouts[pay.checkoutId].paymentStatus = "paid"
        state.checkouts[pay.checkoutId].status = "paid"
      end
      audit.record("catalog", "CapturePayment", msg, nil, { paymentId = pay.paymentId })
      metrics.inc "catalog.CapturePayment.count"
      metrics.tick()
      return codec.ok { paymentId = pay.paymentId, status = pay.status }
    end
    
    function handlers.RefundPayment(msg)
      local ok, missing = validation.require_fields(msg, { "Payment-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Payment-Id",
        "Amount",
        "Reason",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local pay = state.payments[msg["Payment-Id"]]
      if not pay then
        return codec.error("NOT_FOUND", "Payment not found")
      end
      local amount = msg.Amount or pay.amount
      if type(amount) ~= "number" or amount <= 0 then
        return codec.error("INVALID_INPUT", "Amount must be positive number")
      end
      if PSP_HOSTED_ONLY and pay.provider ~= "internal" then
        return codec.error(
          "PSP_NOT_CONFIGURED",
          "Server-side refund disabled; use hosted PSP",
          { provider = pay.provider }
        )
      end
      pay.status = "refunded"
      pay.refundAmount = amount
      pay.refundedAt = os.time()
      if pay.provider ~= "internal" then
        pay.providerRefundId = "rf_" .. pay.paymentId
      end
      table.insert(state.payment_attempts[pay.paymentId] or {}, {
        ts = os.time(),
        event = "refunded",
        status = pay.status,
        amount = amount,
      })
      if pay.orderId and state.orders[pay.orderId] then
        state.orders[pay.orderId].refundAmount = amount
        state.orders[pay.orderId].paymentStatus = "refunded"
        state.orders[pay.orderId].status = state.orders[pay.orderId].status or "refunded"
      end
      audit.record("catalog", "RefundPayment", msg, nil, { paymentId = pay.paymentId, amount = amount })
      metrics.inc "catalog.RefundPayment.count"
      metrics.tick()
      return codec.ok { paymentId = pay.paymentId, status = pay.status, amount = amount }
    end
    
    local function parse_header(headers, key)
      if not headers then
        return nil
      end
      return headers[key] or headers[key:lower()] or headers[key:upper()]
    end
    
    local function mark_webhook_seen(cache_key, ts)
      ts = ts or os.time()
      local existing = state.webhook_seen[cache_key]
      if existing and (ts - existing) <= WEBHOOK_REPLAY_WINDOW then
        return false, "replay"
      end
      state.webhook_seen[cache_key] = ts
      return true
    end
    
    local function verify_provider_webhook(provider, msg, raw_body)
      raw_body = raw_body or ""
      if provider == "stripe" then
        if not STRIPE_WEBHOOK_SECRET or STRIPE_WEBHOOK_SECRET == "" then
          return false, "stripe_secret_missing"
        end
        if STRIPE_WEBHOOK_ID and STRIPE_WEBHOOK_ID ~= "" then
          local hook = msg["Webhook-Id"] or parse_header(msg.Headers, "Stripe-Webhook-Id")
          if hook ~= STRIPE_WEBHOOK_ID then
            return false, "stripe_webhook_id_mismatch"
          end
        end
        local sig_header = msg.Signature or parse_header(msg.Headers, "Stripe-Signature")
        if not sig_header then
          return false, "missing_signature"
        end
        local t = sig_header:match "t=(%d+)"
        local v1 = sig_header:match "v1=([0-9a-fA-F]+)"
        if not t or not v1 then
          return false, "signature_format"
        end
        local expected = hmac_sha256_hex(t .. "." .. raw_body, STRIPE_WEBHOOK_SECRET)
        if not expected or expected:lower() ~= v1:lower() then
          return false, "signature_mismatch"
        end
        local ts_num = tonumber(t) or 0
        if math.abs(os.time() - ts_num) > WEBHOOK_REPLAY_WINDOW then
          return false, "timestamp_out_of_window"
        end
        local ok_seen, err_seen = mark_webhook_seen("stripe:" .. v1, ts_num)
        if not ok_seen then
          return false, err_seen
        end
        return true
      elseif provider == "paypal" then
        if not PAYPAL_WEBHOOK_SECRET or PAYPAL_WEBHOOK_SECRET == "" then
          return false, "paypal_secret_missing"
        end
        if PAYPAL_WEBHOOK_ID and PAYPAL_WEBHOOK_ID ~= "" then
          local hook = msg["Webhook-Id"] or parse_header(msg.Headers, "Webhook-Id")
          if hook ~= PAYPAL_WEBHOOK_ID then
            return false, "paypal_webhook_id_mismatch"
          end
        end
        local sig = msg.Signature or parse_header(msg.Headers, "PayPal-Transmission-Sig")
        if not sig then
          return false, "missing_signature"
        end
        local expected = hmac_sha256_hex(raw_body, PAYPAL_WEBHOOK_SECRET)
        if not expected or expected:lower() ~= tostring(sig):lower() then
          return false, "signature_mismatch"
        end
        local transmission_id = msg["Transmission-Id"]
          or parse_header(msg.Headers, "PayPal-Transmission-Id")
        local ts = tonumber(msg.Timestamp or parse_header(msg.Headers, "PayPal-Transmission-Time"))
          or os.time()
        local replay_key = transmission_id or sig
        local ok_seen, err_seen = mark_webhook_seen("paypal:" .. replay_key, ts)
        if not ok_seen then
          return false, err_seen
        end
        return true
      elseif provider == "adyen" then
        if not ADYEN_HMAC_KEY or ADYEN_HMAC_KEY == "" then
          return false, "adyen_secret_missing"
        end
        local sig = msg.Signature or parse_header(msg.Headers, "Hmac-Signature")
        if not sig then
          return false, "missing_signature"
        end
        local expected = hmac_sha256_hex(raw_body, ADYEN_HMAC_KEY)
        if not expected or expected:lower() ~= tostring(sig):lower() then
          return false, "signature_mismatch"
        end
        local ok_seen, err_seen = mark_webhook_seen("adyen:" .. sig, os.time())
        if not ok_seen then
          return false, err_seen
        end
        return true
      end
      return false, "provider_not_supported"
    end
    
    function handlers.HandlePaymentProviderWebhook(msg)
      local ok, missing = validation.require_fields(msg, { "Provider", "Event" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      if PSP_HOSTED_ONLY then
        return codec.error(
          "PSP_NOT_CONFIGURED",
          "Hosted-only PSP mode; provider webhooks disabled",
          { provider = msg.Provider }
        )
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Provider",
        "Event",
        "RawBody",
        "Headers",
        "Timestamp",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local raw_body = msg.RawBody
      if not raw_body and json_ok then
        local ok_enc, body = pcall(cjson.encode, msg.Event)
        raw_body = ok_enc and body or ""
      end
      local sig_ok, sig_err = verify_provider_webhook(msg.Provider, msg, raw_body or "")
      if not sig_ok then
        metrics.inc "catalog.HandlePaymentProviderWebhook.verify_failed"
        return codec.error("FORBIDDEN", "Signature verification failed", { reason = sig_err })
      end
      if msg.Provider:lower() == "paypal" then
        -- PayPal deterministic signature with webhook id
        local tid = msg["Transmission-Id"] or parse_header(msg.Headers, "PayPal-Transmission-Id") or ""
        local tts = msg["Transmission-Time"]
          or parse_header(msg.Headers, "PayPal-Transmission-Time")
          or ""
        local wid = msg["Webhook-Id"]
          or parse_header(msg.Headers, "Webhook-Id")
          or PAYPAL_WEBHOOK_ID
          or ""
        local signed = table.concat({ tid, tts, wid, raw_body or "" }, "|")
        local expected = hmac_sha256_hex(signed, PAYPAL_WEBHOOK_SECRET)
        local provided = msg.Signature or parse_header(msg.Headers, "PayPal-Transmission-Sig")
        if not expected or not provided or expected:lower() ~= tostring(provided):lower() then
          return codec.error(
            "FORBIDDEN",
            "Signature verification failed",
            { reason = "paypal_sig_mismatch" }
          )
        end
        local cert_url = parse_header(msg.Headers, "PayPal-Cert-Url")
        if cert_url then
          local host = hostname_from_url(cert_url)
          if not host or not host:match(PAYPAL_CERT_HOST:gsub("%.", "%%.") .. "$") then
            return codec.error("FORBIDDEN", "Cert host not allowed")
          end
          local cert_pem, cerr = fetch_paypal_cert(cert_url)
          if not cert_pem then
            return codec.error("FORBIDDEN", "Cert fetch failed", { reason = cerr })
          end
          local ok_cert, cert_err = verify_paypal_cert_signature(signed, provided, cert_pem)
          if not ok_cert then
            return codec.error("FORBIDDEN", "Cert signature invalid", { reason = cert_err })
          end
        end
      end
      local ev = msg.Event
      if type(ev) ~= "table" then
        return codec.error("INVALID_INPUT", "Event must be object")
      end
      local provider = msg.Provider:lower()
      -- normalize PayPal resource wrapper
      if provider == "paypal" and ev.resource and type(ev.resource) == "table" then
        ev = ev.resource
      end
      -- basic freshness check if provider sends creation time
      if ev.created and math.abs(os.time() - (tonumber(ev.created) or 0)) > WEBHOOK_REPLAY_WINDOW then
        return codec.error("FORBIDDEN", "Event too old", { created = ev.created })
      end
      if provider == "adyen" and ev.additionalData and ev.additionalData["hmacSignature"] then
        -- Adyen already verified at webhook layer; prefer pspReference as id
        ev.pspReference = ev.pspReference or ev.additionalData["pspReference"]
        if ev.success == false or ev.success == "false" then
          return codec.error("FORBIDDEN", "Adyen event not successful")
        end
      end
      -- Ensure paymentId present early for idempotency cache write
      local allowed_types = {
        stripe = {
          ["payment_intent.succeeded"] = "payment_succeeded",
          ["payment_intent.payment_failed"] = "payment_failed",
          ["charge.refunded"] = "refund_succeeded",
        },
        paypal = {
          ["CHECKOUT.ORDER.APPROVED"] = "payment_succeeded",
          ["PAYMENT.CAPTURE.COMPLETED"] = "payment_succeeded",
          ["PAYMENT.CAPTURE.DENIED"] = "payment_failed",
          ["PAYMENT.CAPTURE.REFUNDED"] = "refund_succeeded",
        },
        adyen = {
          ["AUTHORISATION"] = "payment_succeeded",
          ["CANCELLATION"] = "payment_failed",
          ["REFUND"] = "refund_succeeded",
        },
      }
      if allowed_types[provider] and ev.type then
        ev.type = allowed_types[provider][ev.type] or ev.type
      end
      if allowed_types[provider] and not allowed_types[provider][ev.type or ""] then
        return codec.error("INVALID_INPUT", "Event type not allowed", { type = ev.type })
      end
      if provider == "stripe" then
        local cached = check_stripe_idempotency(msg)
        if cached then
          return codec.ok(cached)
        end
      end
      local pid = ev.paymentId or ev.payment_id
      if not pid then
        return codec.error("INVALID_INPUT", "paymentId missing in event")
      end
      if
        not ev.id
        and not ev.eventId
        and not ev.event_id
        and not ev.pspReference
        and not ev.resourceId
      then
        return codec.error("INVALID_INPUT", "event id missing")
      end
      local event_id = ev.id or ev.eventId or ev.event_id or ev.pspReference or ev.resourceId
      local ts = tonumber(msg.Timestamp) or os.time()
      if event_id then
        local ok_seen, err_seen = mark_event_seen(msg.Provider, event_id, ts)
        if not ok_seen then
          return codec.error("CONFLICT", "Duplicate webhook", { reason = err_seen, eventId = event_id })
        end
      end
      if provider == "adyen" and ev.pspReference then
        local ok_seen, err_seen = mark_event_seen("adyen_psp", ev.pspReference, ts)
        if not ok_seen then
          return codec.error("CONFLICT", "Duplicate PSP reference", { reason = err_seen })
        end
      end
      local pay = state.payments[pid]
      if not pay then
        return codec.error("NOT_FOUND", "Payment not found")
      end
      if msg.Provider:lower() == "stripe" then
        pay.stripeIdempotencyKey = msg.IdempotencyKey or parse_header(msg.Headers, "Idempotency-Key")
      end
      local ok_evt, evt_err = validate_payment_event(ev, pay)
      if not ok_evt then
        return codec.error("INVALID_INPUT", "Event rejected", { reason = evt_err })
      end
      if provider == "stripe" and STRIPE_VERIFY_EVENT and ev.id then
        local fetched, ferr = stripe_fetch_event(ev.id)
        if not fetched or type(fetched) ~= "table" then
          return codec.error("FORBIDDEN", "Stripe event fetch failed", { reason = ferr })
        end
        local obj = fetched.data and fetched.data.object or {}
        local pi = obj.id or obj.payment_intent or obj.payment_intent_id
        if pi and pi ~= pid then
          return codec.error(
            "FORBIDDEN",
            "Stripe event payment mismatch",
            { fetchedPayment = pi, expected = pid }
          )
        end
        if obj.amount_received and obj.amount_received / 100 > pay.amount + 0.01 then
          return codec.error("FORBIDDEN", "Stripe event amount mismatch")
        end
        if obj.currency and pay.currency and obj.currency:upper() ~= pay.currency:upper() then
          return codec.error("FORBIDDEN", "Stripe event currency mismatch")
        end
      end
      local before = pay.status
      if ev.type == "payment_succeeded" then
        if before ~= "refunded" then
          pay.status = "captured"
          pay.capturedAt = os.time()
        end
      elseif ev.type == "payment_failed" then
        if before ~= "captured" and before ~= "refunded" then
          pay.status = "failed"
        end
      elseif ev.type == "refund_succeeded" then
        pay.status = "refunded"
        pay.refundAmount = ev.amount or ev.refundAmount or pay.amount
      end
      audit.record("catalog", "HandlePaymentProviderWebhook", msg, nil, {
        paymentId = pid,
        status = pay.status,
        provider = msg.Provider,
        eventId = event_id,
        statusBefore = before,
      })
      if provider == "stripe" then
        cache_stripe_idempotency(msg, { paymentId = pid, status = pay.status })
      end
      return codec.ok { paymentId = pid, status = pay.status }
    end
    
    function handlers.CleanupRetention(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      cleanup_retention()
      audit.record("catalog", "CleanupRetention", msg, nil, { retentionDays = RETENTION_DAYS })
      return codec.ok { retentionDays = RETENTION_DAYS }
    end
    
    function handlers.ListNotificationFailures(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Clear",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local site = msg["Site-Id"] or "global"
      local items = state.notification_failures[site] or {}
      if msg.Clear == true or msg.Clear == "true" then
        state.notification_failures[site] = {}
      end
      return codec.ok { siteId = site, failures = items, total = #items }
    end
    
    function handlers.ExportRecommendations(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Limit",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local limit = tonumber(msg.Limit) or 20
      if limit < 1 then
        limit = 1
      end
      if limit > 200 then
        limit = 200
      end
      local events = state.events[msg["Site-Id"]] or {}
      local list = {}
      for sku, stats in pairs(events) do
        local score = (stats.purchases or 0) * 3
          + (stats.add_to_cart or 0) * 1.5
          + (stats.views or 0) * 0.2
        table.insert(list, { sku = sku, score = score, stats = stats })
      end
      table.sort(list, function(a, b)
        return (a.score or 0) > (b.score or 0)
      end)
      while #list > limit do
        table.remove(list)
      end
      return codec.ok { siteId = msg["Site-Id"], items = list, total = #list }
    end
    
    function handlers.ImportCatalogCSV(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Path" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Path",
        "DryRun",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local f = io.open(msg.Path, "r")
      if not f then
        return codec.error("NOT_FOUND", "File not found", { path = msg.Path })
      end
      local header = f:read "*l"
      if not header then
        f:close()
        return codec.error("INVALID_INPUT", "Empty file")
      end
      local cols = parse_csv_line(header)
      local idx = {}
      for i, col in ipairs(cols) do
        idx[col:lower()] = i
      end
      local required = { "sku", "name", "price", "currency" }
      for _, r in ipairs(required) do
        if not idx[r] then
          f:close()
          return codec.error("INVALID_INPUT", "Missing column " .. r)
        end
      end
      local imported = 0
      local dry = msg.DryRun == true or msg.DryRun == "true"
      for line in f:lines() do
        if line ~= "" then
          local fields = parse_csv_line(line)
          local sku = fields[idx.sku]
          local name = fields[idx.name]
          local price = tonumber(fields[idx.price])
          local currency = fields[idx.currency]
          if not (sku and name and price and currency) then
            f:close()
            return codec.error("INVALID_INPUT", "Missing required fields on line", { line = line })
          end
          imported = imported + 1
          if imported > IMPORT_MAX_ROWS then
            f:close()
            return codec.error("INVALID_INPUT", "Import too large", { limit = IMPORT_MAX_ROWS })
          end
          if not dry then
            local payload = {
              sku = sku,
              name = name,
              price = price,
              currency = currency,
              description = idx.description and fields[idx.description] or nil,
              categoryId = idx.category and fields[idx.category] or nil,
              taxClass = idx.taxclass and fields[idx.taxclass] or nil,
            }
            if idx.weight and fields[idx.weight] then
              payload.weight = tonumber(fields[idx.weight])
            end
            if idx.assets and fields[idx.assets] then
              payload.assets = {}
              for token in fields[idx.assets]:gmatch "[^,; ]+" do
                table.insert(payload.assets, token)
              end
            end
            if idx.attributes and fields[idx.attributes] and json_ok then
              local ok_attr, attrs = pcall(cjson.decode, fields[idx.attributes])
              if ok_attr and type(attrs) == "table" then
                payload.attributes = attrs
              end
            end
            local key = ids.product_key(msg["Site-Id"], sku)
            state.products[key] = { payload = payload }
            if idx.stock and fields[idx.stock] then
              local qty = tonumber(fields[idx.stock]) or 0
              state.inventory[msg["Site-Id"]] = state.inventory[msg["Site-Id"]] or {}
              state.inventory[msg["Site-Id"]]["default"] = state.inventory[msg["Site-Id"]]["default"]
                or {}
              state.inventory[msg["Site-Id"]]["default"][sku] = qty
            end
            if (idx.region or idx.valid_from or idx.valid_to) and price then
              add_price_window(msg["Site-Id"], currency, {
                region = idx.region and fields[idx.region] or nil,
                valid_from = idx.valid_from and fields[idx.valid_from] or nil,
                valid_to = idx.valid_to and fields[idx.valid_to] or nil,
                prices = { [sku] = price },
              })
            end
          end
        end
      end
      f:close()
      audit.record(
        "catalog",
        "ImportCatalogCSV",
        msg,
        nil,
        { siteId = msg["Site-Id"], imported = imported, dryRun = dry }
      )
      return codec.ok { imported = imported, dryRun = dry }
    end
    
    function handlers.BulkPriceUpdate(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Updates" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Updates",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_updates, err_updates = validation.assert_type(msg.Updates, "table", "Updates")
      if not ok_updates then
        return codec.error("INVALID_INPUT", err_updates, { field = "Updates" })
      end
      local count = 0
      for _, row in ipairs(msg.Updates) do
        if not row.Sku or not row.Price then
          return codec.error("INVALID_INPUT", "Update requires Sku and Price")
        end
        local key = ids.product_key(msg["Site-Id"], row.Sku)
        if state.products[key] and state.products[key].payload then
          local price = tonumber(row.Price)
          if row.Region or row.ValidFrom or row.ValidTo then
            add_price_window(msg["Site-Id"], row.Currency or state.products[key].payload.currency, {
              region = row.Region,
              valid_from = row.ValidFrom,
              valid_to = row.ValidTo,
              prices = { [row.Sku] = price },
            })
          else
            state.products[key].payload.price = price
            if row.Currency then
              state.products[key].payload.currency = row.Currency
            end
          end
          count = count + 1
        end
      end
      audit.record("catalog", "BulkPriceUpdate", msg, nil, { siteId = msg["Site-Id"], count = count })
      return codec.ok { updated = count }
    end
    
    function handlers.RequestReturn(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Items" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Order-Id",
        "Items",
        "Reason",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_items, err_items = validation.assert_type(msg.Items, "table", "Items")
      if not ok_items then
        return codec.error("INVALID_INPUT", err_items, { field = "Items" })
      end
      local items = {}
      for _, it in ipairs(msg.Items) do
        if not (it.Sku and it.Qty) then
          return codec.error("INVALID_INPUT", "Item requires Sku and Qty")
        end
        table.insert(items, { sku = it.Sku, qty = tonumber(it.Qty) or 0, reason = it.Reason })
      end
      local return_id = gen_id "ret"
      state.returns[return_id] = {
        returnId = return_id,
        siteId = msg["Site-Id"],
        orderId = msg["Order-Id"],
        items = items,
        status = "requested",
        reason = msg.Reason,
        createdAt = os.time(),
        restockFee = msg.RestockFee,
        method = msg.Method or "dropoff",
      }
      audit.record("catalog", "RequestReturn", msg, nil, { returnId = return_id })
      notify_rma(msg["Site-Id"], return_id, "requested", state.returns[return_id])
      metrics.inc "catalog.RequestReturn.count"
      metrics.tick()
      return codec.ok { returnId = return_id, status = "requested" }
    end
    
    function handlers.UpdateReturnStatus(msg)
      local ok, missing = validation.require_fields(msg, { "Return-Id", "Status" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Return-Id",
        "Status",
        "Reason",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ret = state.returns[msg["Return-Id"]]
      if not ret then
        return codec.error("NOT_FOUND", "Return not found")
      end
      local allowed = {
        requested = true,
        authorized = true,
        in_transit = true,
        received = true,
        inspected = true,
        refunded = true,
        rejected = true,
      }
      if not allowed[msg.Status] then
        return codec.error("INVALID_INPUT", "Unsupported status")
      end
      ret.status = msg.Status
      ret.reason = msg.Reason or ret.reason
      ret.updatedAt = os.time()
      audit.record(
        "catalog",
        "UpdateReturnStatus",
        msg,
        nil,
        { returnId = ret.returnId, status = ret.status }
      )
      notify_rma(ret.siteId, ret.returnId, "status", { status = ret.status, reason = ret.reason })
      return codec.ok { returnId = ret.returnId, status = ret.status }
    end
    
    function handlers.ApproveReturn(msg)
      local ok, missing = validation.require_fields(msg, { "Return-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Return-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ret = state.returns[msg["Return-Id"]]
      if not ret then
        return codec.error("NOT_FOUND", "Return not found")
      end
      ret.status = "approved"
      ret.approvedAt = os.time()
      audit.record("catalog", "ApproveReturn", msg, nil, { returnId = ret.returnId })
      notify_rma(ret.siteId, ret.returnId, "approved", { status = ret.status })
      metrics.inc "catalog.ApproveReturn.count"
      metrics.tick()
      return codec.ok { returnId = ret.returnId, status = ret.status }
    end
    
    function handlers.RefundReturn(msg)
      local ok, missing = validation.require_fields(msg, { "Return-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Return-Id",
        "Amount",
        "Restock",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ret = state.returns[msg["Return-Id"]]
      if not ret then
        return codec.error("NOT_FOUND", "Return not found")
      end
      local amount = msg.Amount
      if amount and (type(amount) ~= "number" or amount <= 0) then
        return codec.error("INVALID_INPUT", "Amount must be positive number")
      end
      ret.status = "refunded"
      ret.refundAmount = amount
      ret.refundedAt = os.time()
      local restock = msg.Restock ~= false
      if restock then
        adjust_inventory(ret.siteId, ret.items, 1)
      end
      if ret.orderId and state.orders[ret.orderId] then
        local o = state.orders[ret.orderId]
        o.status = o.status or "returned"
        o.returnStatus = ret.status
        o.refundAmount = amount or o.refundAmount
      end
      audit.record("catalog", "RefundReturn", msg, nil, { returnId = ret.returnId, amount = amount })
      notify_rma(ret.siteId, ret.returnId, "refunded", { amount = amount, restocked = restock })
      metrics.inc "catalog.RefundReturn.count"
      metrics.tick()
      return codec.ok { returnId = ret.returnId, status = ret.status, restocked = restock }
    end
    
    function handlers.CreateReturnLabel(msg)
      local ok, missing = validation.require_fields(msg, { "Return-Id", "Carrier" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Return-Id",
        "Carrier",
        "Service",
        "Address",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ret = state.returns[msg["Return-Id"]]
      if not ret then
        return codec.error("NOT_FOUND", "Return not found")
      end
      local carrier = msg.Carrier
      local service = msg.Service or "standard"
      local address = msg.Address or ret.address
      if not address or not address.Country then
        return codec.error("INVALID_INPUT", "Address.Country required", { field = "Address" })
      end
      local label = build_label(carrier, service, ret.weight or 0)
      label.returnId = ret.returnId
      label.address = address
      label.base = RETURN_LABEL_BASE
      state.shipments[label.shipmentId] = label
      ret.returnLabel = label
      notify_rma(
        ret.siteId,
        ret.returnId,
        "label",
        { shipmentId = label.shipmentId, carrier = carrier }
      )
      audit.record(
        "catalog",
        "CreateReturnLabel",
        msg,
        nil,
        { returnId = ret.returnId, shipmentId = label.shipmentId }
      )
      return codec.ok(label)
    end
    
    function handlers.ExportTelemetry(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local events = state.telemetry
      state.telemetry = {}
      if TELEMETRY_EXPORT_PATH and TELEMETRY_EXPORT_PATH ~= "" and json_ok then
        local f = io.open(TELEMETRY_EXPORT_PATH, "a")
        if f then
          for _, ev in ipairs(events) do
            local ok, line = pcall(cjson.encode, ev)
            if ok and line then
              f:write(line)
              f:write "\n"
            end
          end
          f:close()
        end
      end
      return codec.ok { events = events, count = #events, path = TELEMETRY_EXPORT_PATH }
    end
    
    -- B2B / Purchase Orders ---------------------------------------------------
    function handlers.CreateCompanyAccount(msg)
      local ok, missing = validation.require_fields(msg, { "Name" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Company-Id",
        "Name",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local cid = msg["Company-Id"] or gen_id "co"
      state.companies[cid] = state.companies[cid] or { name = msg.Name, users = {} }
      state.company_terms[cid] = state.company_terms[cid]
        or {
          credit_limit = msg["Credit-Limit"],
          currency = msg.Currency or "USD",
          net_terms = msg["Net-Terms"] or "NET30",
          balance = 0,
        }
      audit.record("catalog", "CreateCompanyAccount", msg, nil, { companyId = cid })
      return codec.ok { companyId = cid, name = msg.Name }
    end
    
    function handlers.SetCompanyTerms(msg)
      local ok, missing =
        validation.require_fields(msg, { "Company-Id", "Credit-Limit", "Currency", "Net-Terms" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      state.company_terms[msg["Company-Id"]] = state.company_terms[msg["Company-Id"]] or { balance = 0 }
      local t = state.company_terms[msg["Company-Id"]]
      t.credit_limit = msg["Credit-Limit"]
      t.currency = msg.Currency
      t.net_terms = msg["Net-Terms"]
      return codec.ok {
        companyId = msg["Company-Id"],
        creditLimit = t.credit_limit,
        netTerms = t.net_terms,
        balance = t.balance or 0,
      }
    end
    
    function handlers.AddCompanyUser(msg)
      local ok, missing = validation.require_fields(msg, { "Company-Id", "User-Id", "Role" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Company-Id",
        "User-Id",
        "Role",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_comp, err_comp = ensure_company(msg["Company-Id"])
      if not ok_comp then
        return codec.error("NOT_FOUND", err_comp)
      end
      local role = msg.Role
      if role ~= "buyer" and role ~= "approver" and role ~= "admin" then
        return codec.error("INVALID_INPUT", "Role must be buyer|approver|admin")
      end
      state.companies[msg["Company-Id"]].users[msg["User-Id"]] = role
      audit.record(
        "catalog",
        "AddCompanyUser",
        msg,
        nil,
        { companyId = msg["Company-Id"], userId = msg["User-Id"], role = role }
      )
      return codec.ok { companyId = msg["Company-Id"], userId = msg["User-Id"], role = role }
    end
    
    function handlers.CreatePurchaseOrder(msg)
      local ok, missing =
        validation.require_fields(msg, { "Site-Id", "Company-Id", "Items", "Address" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Company-Id",
        "Items",
        "Address",
        "Currency",
        "Promo",
        "Buyer-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_comp, err_comp = ensure_company(msg["Company-Id"])
      if not ok_comp then
        return codec.error("NOT_FOUND", err_comp)
      end
      if
        msg["Buyer-Id"]
        and not require_company_role(msg["Company-Id"], msg["Buyer-Id"], { "buyer", "admin" })
      then
        return codec.error("FORBIDDEN", "Buyer not allowed for company")
      end
      local currency = msg.Currency or "USD"
      local cart, cart_err = compute_cart(msg["Site-Id"], msg.Items, currency, msg.Promo)
      if not cart then
        return codec.error("INVALID_INPUT", cart_err or "Pricing failed")
      end
      local address = msg.Address
      if type(address) ~= "table" or not address.Country then
        return codec.error("INVALID_INPUT", "Address.Country required", { field = "Address" })
      end
      local dims = nil
      if msg.Dimensions then
        dims = {
          length = tonumber(msg.Dimensions.Length),
          width = tonumber(msg.Dimensions.Width),
          height = tonumber(msg.Dimensions.Height),
        }
      end
      local shipping = pick_shipping(msg["Site-Id"], address, cart.subtotal, cart.weight, dims)
      local tax_rate = pick_tax_rate(msg["Site-Id"], address)
      local tax = cart.subtotal * tax_rate / 100
      local total = cart.subtotal + shipping.rate + tax
      local po_id = gen_id "po"
      state.purchase_orders[po_id] = {
        poId = po_id,
        siteId = msg["Site-Id"],
        companyId = msg["Company-Id"],
        items = cart.lines,
        address = address,
        currency = currency,
        subtotal = cart.subtotal,
        weight = cart.weight,
        tax = tax,
        taxRate = tax_rate,
        shipping = shipping,
        total = total,
        promo = msg.Promo,
        status = "pending_approval",
        approvals = {},
      }
      audit.record("catalog", "CreatePurchaseOrder", msg, nil, { poId = po_id, total = total })
      return codec.ok { poId = po_id, status = "pending_approval", total = total, currency = currency }
    end
    
    function handlers.ApprovePurchaseOrder(msg)
      local ok, missing = validation.require_fields(msg, { "PO-Id", "Approver-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "PO-Id",
        "Approver-Id",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local po = state.purchase_orders[msg["PO-Id"]]
      if not po then
        return codec.error("NOT_FOUND", "Purchase order not found")
      end
      if not require_company_role(po.companyId, msg["Approver-Id"], { "approver", "admin" }) then
        return codec.error("FORBIDDEN", "Approver not allowed")
      end
      po.status = "approved"
      po.approvals[msg["Approver-Id"]] = "approved"
      audit.record("catalog", "ApprovePurchaseOrder", msg, nil, { poId = po.poId })
      return codec.ok { poId = po.poId, status = po.status }
    end
    
    function handlers.RejectPurchaseOrder(msg)
      local ok, missing = validation.require_fields(msg, { "PO-Id", "Approver-Id", "Reason" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "PO-Id",
        "Approver-Id",
        "Reason",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local po = state.purchase_orders[msg["PO-Id"]]
      if not po then
        return codec.error("NOT_FOUND", "Purchase order not found")
      end
      if not require_company_role(po.companyId, msg["Approver-Id"], { "approver", "admin" }) then
        return codec.error("FORBIDDEN", "Approver not allowed")
      end
      po.status = "rejected"
      po.approvals[msg["Approver-Id"]] = "rejected"
      po.rejectionReason = msg.Reason
      audit.record("catalog", "RejectPurchaseOrder", msg, nil, { poId = po.poId })
      return codec.ok { poId = po.poId, status = po.status, reason = msg.Reason }
    end
    
    function handlers.CheckoutPurchaseOrder(msg)
      local ok, missing = validation.require_fields(msg, { "PO-Id", "Payment-Method" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "PO-Id",
        "Payment-Method",
        "Require3DS",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local po = state.purchase_orders[msg["PO-Id"]]
      if not po then
        return codec.error("NOT_FOUND", "Purchase order not found")
      end
      if po.status ~= "approved" then
        return codec.error("INVALID_STATE", "PO not approved", { status = po.status })
      end
      local terms = state.company_terms[po.companyId]
      if terms and terms.credit_limit and terms.balance then
        if (terms.balance + po.total) > terms.credit_limit then
          return codec.error("CREDIT_LIMIT_EXCEEDED", "PO exceeds credit limit", {
            creditLimit = terms.credit_limit,
            balance = terms.balance,
          })
        end
      end
      -- create checkout-like record without re-quoting
      local items = {}
      for _, line in ipairs(po.items) do
        table.insert(items, { sku = line.sku, qty = line.qty })
      end
      local ok_reserve, changes, backorders = reserve_inventory(po.siteId, items)
      if not ok_reserve then
        return codec.error("OUT_OF_STOCK", "Insufficient inventory")
      end
      local checkout_id = gen_id "chk"
      state.checkouts[checkout_id] = {
        siteId = po.siteId,
        items = items,
        address = po.address,
        email = po.email,
        quote = {
          subtotal = po.subtotal,
          weight = po.weight,
          taxRate = po.taxRate,
          tax = po.tax,
          shipping = po.shipping,
          total = po.total,
          currency = po.currency,
          promo = po.promo,
        },
        status = "pending_payment",
        reserve = changes,
        backorders = backorders,
        poId = po.poId,
        risk = risk_score { quote = { total = po.total, shipping = po.shipping }, address = po.address },
      }
      for _, bo in ipairs(backorders or {}) do
        record_backorder(po.siteId, bo.sku, bo.qty, "po", checkout_id, bo.preorder_at, bo.eta_days)
      end
      local payment = create_payment_intent_internal {
        siteId = po.siteId,
        checkoutId = checkout_id,
        amount = po.total,
        currency = po.currency,
        method = msg["Payment-Method"],
        require3ds = msg.Require3DS,
        provider = msg.Provider,
      }
      po.status = "in_checkout"
      po.checkoutId = checkout_id
      if terms then
        terms.balance = (terms.balance or 0) + po.total
      end
      audit.record(
        "catalog",
        "CheckoutPurchaseOrder",
        msg,
        nil,
        { poId = po.poId, checkoutId = checkout_id }
      )
      return codec.ok {
        poId = po.poId,
        checkoutId = checkout_id,
        paymentId = payment.paymentId,
        paymentStatus = payment.status,
        total = po.total,
        currency = po.currency,
      }
    end
    
    -- Invoicing ---------------------------------------------------------------
    local function persist_invoice(inv)
      if INVOICE_EXPORT_PATH and INVOICE_EXPORT_PATH ~= "" and json_ok then
        local f = io.open(INVOICE_EXPORT_PATH, "a")
        if f then
          local ok, line = pcall(cjson.encode, inv)
          if ok and line then
            f:write(line)
            f:write "\n"
          end
          f:close()
        end
      end
      if INVOICE_PDF_DIR and INVOICE_PDF_DIR ~= "" then
        os.execute("mkdir -p " .. INVOICE_PDF_DIR)
        local path = string.format("%s/%s.pdf", INVOICE_PDF_DIR, inv.invoiceId)
        local f = io.open(path, "w")
        if f then
          f:write(string.format("INVOICE %s (%s)\n", inv.invoiceNumber or inv.invoiceId, inv.siteId))
          f:write(
            string.format(
              "Order: %s\nCurrency: %s\nTotal: %.2f\n",
              inv.orderId or "-",
              inv.currency,
              inv.total or 0
            )
          )
          f:write "Lines:\n"
          for _, line in ipairs(inv.lines or {}) do
            f:write(
              string.format(
                "- %s x%s @ %s\n",
                line.sku or line.Sku or "item",
                line.qty or line.Qty or "1",
                line.unit_price or line.price or "?"
              )
            )
          end
          f:write(
            string.format(
              "Tax: %.2f\nShipping: %.2f\nIssued: %s\n",
              inv.tax or 0,
              inv.shipping or 0,
              inv.issuedAt or ""
            )
          )
          f:close()
          inv.pdfPath = path
        end
      end
      if INVOICE_S3_BUCKET and INVOICE_S3_BUCKET ~= "" and inv.pdfPath then
        local ok = s3_copy_with_retry(inv.pdfPath, INVOICE_S3_BUCKET)
        if ok then
          inv.s3Url = string.format("s3://%s/%s", INVOICE_S3_BUCKET, inv.invoiceId .. ".pdf")
        end
      end
      -- render HTML->PDF via external tool if configured
      local rendered = render_invoice_pdf(inv)
      if rendered then
        inv.pdfPath = rendered
        if INVOICE_S3_BUCKET and INVOICE_S3_BUCKET ~= "" then
          local ok = s3_copy_with_retry(inv.pdfPath, INVOICE_S3_BUCKET)
          if ok then
            inv.s3Url = string.format("s3://%s/%s", INVOICE_S3_BUCKET, inv.invoiceId .. ".pdf")
          end
        end
      end
      -- attach signature if secret present
      if INVOICE_SIGN_SECRET and json_ok then
        local ok_enc, body = pcall(cjson.encode, inv)
        if ok_enc then
          inv.signature = auth.hmac(body, INVOICE_SIGN_SECRET)
        end
      end
    end
    
    function handlers.CreateInvoice(msg)
      local ok, missing = validation.require_fields(msg, { "Site-Id", "Order-Id", "Lines" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Order-Id",
        "Lines",
        "Currency",
        "Total",
        "Tax",
        "Shipping",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_lines, err_lines = validation.assert_type(msg.Lines, "table", "Lines")
      if not ok_lines or #msg.Lines == 0 then
        return codec.error("INVALID_INPUT", err_lines or "Lines must be non-empty", { field = "Lines" })
      end
      local currency = msg.Currency or "USD"
      local total = msg.Total
      local lines_total = 0
      for _, line in ipairs(msg.Lines) do
        local qty = tonumber(line.qty or line.Qty or line.quantity or 0) or 0
        local unit = tonumber(line.unit_price or line.Unit or line.price or 0) or 0
        if qty <= 0 or unit < 0 then
          return codec.error("INVALID_INPUT", "Line qty/unit_price invalid", { line = line })
        end
        lines_total = lines_total + qty * unit
      end
      if total == nil then
        total = lines_total + (msg.Tax or 0) + (msg.Shipping or 0)
      elseif type(total) ~= "number" or total < 0 then
        return codec.error("INVALID_INPUT", "Total must be non-negative number")
      end
      local inv_id = gen_id "inv"
      local year = os.date "%Y"
      local seq
      if INVOICE_NUMBER_WITH_YEAR then
        state.invoice_seq_year[msg["Site-Id"]] = state.invoice_seq_year[msg["Site-Id"]] or {}
        seq = (state.invoice_seq_year[msg["Site-Id"]][year] or 0) + 1
        state.invoice_seq_year[msg["Site-Id"]][year] = seq
      else
        seq = (state.invoice_seq[msg["Site-Id"]] or 0) + 1
        state.invoice_seq[msg["Site-Id"]] = seq
      end
      local invoice_number = INVOICE_NUMBER_WITH_YEAR
          and string.format("%s-%s-%06d", msg["Site-Id"], year, seq)
        or string.format("%s-%06d", msg["Site-Id"], seq)
      local inv = {
        invoiceId = inv_id,
        invoiceNumber = invoice_number,
        siteId = msg["Site-Id"],
        orderId = msg["Order-Id"],
        currency = currency,
        lines = msg.Lines,
        tax = msg.Tax or 0,
        shipping = msg.Shipping or 0,
        total = total,
        issuedAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
        status = "issued",
        pdfUrl = string.format("%s%s.pdf", CARRIER_LABEL_BASE, inv_id),
      }
      state.invoices[inv_id] = inv
      persist_invoice(inv)
      audit.record("catalog", "CreateInvoice", msg, nil, { invoiceId = inv_id, orderId = inv.orderId })
      return codec.ok(inv)
    end
    
    function handlers.GetInvoice(msg)
      local ok, missing = validation.require_fields(msg, { "Invoice-Id" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Invoice-Id", "Actor-Role", "Schema-Version" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local inv = state.invoices[msg["Invoice-Id"]]
      if not inv then
        return codec.error("NOT_FOUND", "Invoice not found")
      end
      return codec.ok(inv)
    end
    
    function handlers.ListInvoices(msg)
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Site-Id",
        "Order-Id",
        "Actor-Role",
        "Schema-Version",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local items = {}
      for _, inv in pairs(state.invoices) do
        if not msg["Site-Id"] or inv.siteId == msg["Site-Id"] then
          if not msg["Order-Id"] or inv.orderId == msg["Order-Id"] then
            table.insert(items, inv)
          end
        end
      end
      table.sort(items, function(a, b)
        return (a.issuedAt or "") > (b.issuedAt or "")
      end)
      return codec.ok { total = #items, items = items }
    end
    
    local function route(msg)
      local ok, missing = validation.require_tags(msg, { "Action" })
      if not ok then
        return codec.missing_tags(missing)
      end
    
      local ok_sec, sec_err = auth.enforce(msg)
      if not ok_sec then
        return codec.error("FORBIDDEN", sec_err)
      end
    
      local seen = idem.check(msg["Request-Id"])
      if seen then
        return seen
      end
    
      local ok_action, err = validation.require_action(msg, allowed_actions)
      if not ok_action then
        if err == "unknown_action" then
          return codec.unknown_action(msg.Action)
        end
        return codec.error("MISSING_ACTION", "Action is required")
      end
    
      local ok_hmac, hmac_err = auth.verify_outbox_hmac(msg)
      if not ok_hmac then
        return codec.error("FORBIDDEN", hmac_err)
      end
    
      local ok_role, role_err = auth.require_role_for_action(msg, role_policy)
      if not ok_role then
        return codec.error("FORBIDDEN", role_err)
      end
    
      local handler = handlers[msg.Action]
      if not handler then
        return codec.unknown_action(msg.Action)
      end
    
      local resp = handler(msg)
      metrics.inc("catalog." .. msg.Action .. ".count")
      metrics.tick()
      idem.record(msg["Request-Id"], resp)
      persist.save("catalog_state", state)
      return resp
    end
    
    return {
      route = route,
      _state = state,
    }
    ]====], "ao.catalog.process")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.access.process"] = function()
      local loaded, err = load([====[-- Access process handlers: entitlements and protected assets.
    
    local codec = require "ao.shared.codec"
    local validation = require "ao.shared.validation"
    local ids = require "ao.shared.ids"
    local auth = require "ao.shared.auth"
    local idem = require "ao.shared.idempotency"
    local audit = require "ao.shared.audit"
    local schema = require "ao.shared.schema"
    local metrics = require "ao.shared.metrics"
    local persist = require "ao.shared.persist"
    
    local handlers = {}
    local allowed_actions = {
      "HasEntitlement",
      "GetProtectedAssetRef",
      "GrantEntitlement",
      "RevokeEntitlement",
      "PutProtectedAssetRef",
    }
    
    local role_policy = {
      GrantEntitlement = { "admin", "access-admin" },
      RevokeEntitlement = { "admin", "access-admin" },
      PutProtectedAssetRef = { "admin", "access-admin" },
    }
    
    local state = persist.load("access_state", {
      entitlements = {}, -- entitlement:<subject>:<asset> -> policy
      protected = {}, -- asset:<id> -> { ref, visibility }
    })
    
    local MAX_POLICY_BYTES = tonumber(os.getenv "ACCESS_MAX_POLICY_BYTES" or "") or (32 * 1024)
    
    function handlers.HasEntitlement(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Asset" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Subject", "Asset", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_sub, err_sub = validation.check_length(msg.Subject, 128, "Subject")
      if not ok_len_sub then
        return codec.error("INVALID_INPUT", err_sub, { field = "Subject" })
      end
      local ok_len_asset, err_asset = validation.check_length(msg.Asset, 256, "Asset")
      if not ok_len_asset then
        return codec.error("INVALID_INPUT", err_asset, { field = "Asset" })
      end
      local key = ids.entitlement_key(msg.Subject, msg.Asset)
      local policy = state.entitlements[key]
      return codec.ok {
        subject = msg.Subject,
        asset = msg.Asset,
        hasEntitlement = policy ~= nil,
        policy = policy,
      }
    end
    
    function handlers.GetProtectedAssetRef(msg)
      local ok, missing = validation.require_fields(msg, { "Asset" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Asset", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_asset, err_asset = validation.check_length(msg.Asset, 256, "Asset")
      if not ok_len_asset then
        return codec.error("INVALID_INPUT", err_asset, { field = "Asset" })
      end
      local asset = state.protected[msg.Asset]
      if not asset then
        return codec.error("NOT_FOUND", "Asset ref not found", { asset = msg.Asset })
      end
      return codec.ok {
        asset = msg.Asset,
        ref = asset.ref,
        visibility = asset.visibility or "protected",
      }
    end
    
    function handlers.GrantEntitlement(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Asset", "Policy" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Subject",
        "Asset",
        "Policy",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_sub, err_sub = validation.check_length(msg.Subject, 128, "Subject")
      if not ok_len_sub then
        return codec.error("INVALID_INPUT", err_sub, { field = "Subject" })
      end
      local ok_len_asset, err_asset = validation.check_length(msg.Asset, 256, "Asset")
      if not ok_len_asset then
        return codec.error("INVALID_INPUT", err_asset, { field = "Asset" })
      end
      local ok_len_policy, err_policy = validation.check_length(msg.Policy, 64, "Policy")
      if not ok_len_policy then
        return codec.error("INVALID_INPUT", err_policy, { field = "Policy" })
      end
      local ok_schema, schema_err = schema.validate(
        "entitlement",
        { subject = msg.Subject, asset = msg.Asset, policy = msg.Policy }
      )
      if not ok_schema then
        return codec.error("INVALID_INPUT", "Policy failed schema", { errors = schema_err })
      end
      local policy_size = validation.estimate_json_length(msg.Policy)
      local ok_size, err_size = validation.check_size(policy_size, MAX_POLICY_BYTES, "Policy")
      if not ok_size then
        return codec.error("INVALID_INPUT", err_size, { field = "Policy" })
      end
      local key = ids.entitlement_key(msg.Subject, msg.Asset)
      state.entitlements[key] = msg.Policy
      audit.record(
        "access",
        "GrantEntitlement",
        msg,
        nil,
        { subject = msg.Subject, asset = msg.Asset, policy = msg.Policy }
      )
      return codec.ok {
        subject = msg.Subject,
        asset = msg.Asset,
        policy = msg.Policy,
      }
    end
    
    function handlers.RevokeEntitlement(msg)
      local ok, missing = validation.require_fields(msg, { "Subject", "Asset" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(
        msg,
        { "Action", "Request-Id", "Subject", "Asset", "Actor-Role", "Schema-Version", "Signature" }
      )
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_sub, err_sub = validation.check_length(msg.Subject, 128, "Subject")
      if not ok_len_sub then
        return codec.error("INVALID_INPUT", err_sub, { field = "Subject" })
      end
      local ok_len_asset, err_asset = validation.check_length(msg.Asset, 256, "Asset")
      if not ok_len_asset then
        return codec.error("INVALID_INPUT", err_asset, { field = "Asset" })
      end
      local key = ids.entitlement_key(msg.Subject, msg.Asset)
      state.entitlements[key] = nil
      audit.record(
        "access",
        "RevokeEntitlement",
        msg,
        nil,
        { subject = msg.Subject, asset = msg.Asset }
      )
      return codec.ok {
        subject = msg.Subject,
        asset = msg.Asset,
        revoked = true,
      }
    end
    
    function handlers.PutProtectedAssetRef(msg)
      local ok, missing = validation.require_fields(msg, { "Asset", "Ref" })
      if not ok then
        return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
      end
      local ok_extra, extras = validation.require_no_extras(msg, {
        "Action",
        "Request-Id",
        "Asset",
        "Ref",
        "Visibility",
        "Actor-Role",
        "Schema-Version",
        "Signature",
      })
      if not ok_extra then
        return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
      end
      local ok_len_asset, err_asset = validation.check_length(msg.Asset, 256, "Asset")
      if not ok_len_asset then
        return codec.error("INVALID_INPUT", err_asset, { field = "Asset" })
      end
      local ok_len_ref, err_ref = validation.check_length(msg.Ref, 2048, "Ref")
      if not ok_len_ref then
        return codec.error("INVALID_INPUT", err_ref, { field = "Ref" })
      end
      if msg.Visibility then
        local ok_len_vis, err_vis = validation.check_length(msg.Visibility, 32, "Visibility")
        if not ok_len_vis then
          return codec.error("INVALID_INPUT", err_vis, { field = "Visibility" })
        end
      end
      local ok_schema, schema_err = schema.validate(
        "accessAsset",
        { asset = msg.Asset, ref = msg.Ref, visibility = msg.Visibility or "protected" }
      )
      if not ok_schema then
        return codec.error("INVALID_INPUT", "Ref failed schema", { errors = schema_err })
      end
      state.protected[msg.Asset] = { ref = msg.Ref, visibility = msg.Visibility or "protected" }
      audit.record("access", "PutProtectedAssetRef", msg, nil, { asset = msg.Asset, ref = msg.Ref })
      return codec.ok { asset = msg.Asset, ref = msg.Ref }
    end
    
    local function route(msg)
      local ok, missing = validation.require_tags(msg, { "Action" })
      if not ok then
        return codec.missing_tags(missing)
      end
    
      local ok_sec, sec_err = auth.enforce(msg)
      if not ok_sec then
        return codec.error("FORBIDDEN", sec_err)
      end
    
      local seen = idem.check(msg["Request-Id"])
      if seen then
        return seen
      end
    
      local ok_action, err = validation.require_action(msg, allowed_actions)
      if not ok_action then
        if err == "unknown_action" then
          return codec.unknown_action(msg.Action)
        end
        return codec.error("MISSING_ACTION", "Action is required")
      end
    
      local ok_hmac, hmac_err = auth.verify_outbox_hmac(msg)
      if not ok_hmac then
        return codec.error("FORBIDDEN", hmac_err)
      end
    
      local ok_role, role_err = auth.require_role_for_action(msg, role_policy)
      if not ok_role then
        return codec.error("FORBIDDEN", role_err)
      end
    
      local handler = handlers[msg.Action]
      if not handler then
        return codec.unknown_action(msg.Action)
      end
    
      local resp = handler(msg)
      metrics.inc("access." .. msg.Action .. ".count")
      metrics.tick()
      idem.record(msg["Request-Id"], resp)
      persist.save("access_state", state)
      return resp
    end
    
    return {
      route = route,
      _state = state,
    }
    ]====], "ao.access.process")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    
    package.preload["ao.ingest.apply"] = function()
      local loaded, err = load([====[-- Apply events emitted by blackcat-darkmesh-write into AO public state.
    -- Expect events shaped by the minimal write process (see write process emits).
    
    local catalog = require "ao.catalog.process"
    local site = require "ao.site.process"
    local registry = require "ao.registry.process"
    local access = require "ao.access.process"
    local metrics = require "ao.shared.metrics"
    
    local cstate = catalog._state
    local sstate = site._state
    local rstate = registry._state
    local astate = access._state
    
    local export = require "ao.shared.export"
    
    local handlers = {}
    
    local function k(a, b)
      return string.format("%s|%s", a or "", b or "")
    end
    
    local function site_of(ev)
      return ev.siteId or ev.site_id or ev.site or ev.tenant or ev.Tenant or "default"
    end
    
    local function sku_of(ev)
      return ev.sku or ev.Sku
    end
    
    local function event_ts(ev)
      local ts = ev.Timestamp or ev.timestamp or ev.ts or ev.ts_sec or ev.ts_ms
      if type(ts) == "string" and ts:match "^%d+$" then
        ts = tonumber(ts)
      end
      if type(ts) == "number" then
        if ts > 1000000000000 then
          ts = ts / 1000
        end
        return ts
      end
      if type(ts) == "string" then
        local y, m, d, h, min, s = ts:match "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)"
        if y then
          return os.time {
            year = tonumber(y),
            month = tonumber(m),
            day = tonumber(d),
            hour = tonumber(h),
            min = tonumber(min),
            sec = tonumber(s),
            isdst = false,
          }
        end
      end
    end
    
    -- Site routing / content --------------------------------------------------
    function handlers.RouteUpserted(ev)
      sstate.routes[k(site_of(ev), ev.path)] = ev.target
    end
    
    function handlers.PublishPageVersion(ev)
      local key = k(site_of(ev), ev.pageId)
      sstate.pages[key] = {
        version = ev.version,
        publishId = ev.publishId,
        updatedAt = os.time(),
      }
      sstate.active_versions[site_of(ev)] = ev.version
    end
    
    -- Catalog -----------------------------------------------------------------
    function handlers.ProductUpserted(ev)
      cstate.products[k(site_of(ev), ev.sku)] = {
        payload = ev.payload,
        sku = ev.sku,
        siteId = site_of(ev),
        updatedAt = os.time(),
      }
    end
    
    function handlers.InventorySet(ev)
      local site_id = site_of(ev)
      local wh = ev.warehouse or ev.warehouseId or ev["Warehouse-Id"] or "default"
      cstate.inventory[site_id] = cstate.inventory[site_id] or {}
      cstate.inventory[site_id][wh] = cstate.inventory[site_id][wh] or {}
      cstate.inventory[site_id][wh][sku_of(ev)] = tonumber(ev.quantity or 0) or 0
    end
    
    function handlers.ShippingRulesSet(ev)
      cstate.shipping_rules[site_of(ev)] = ev.rules
    end
    
    function handlers.TaxRulesSet(ev)
      cstate.tax_rules[site_of(ev)] = ev.rules
    end
    
    function handlers.PromoAdded(ev)
      local site_id = site_of(ev)
      cstate.promos[site_id] = cstate.promos[site_id] or {}
      cstate.promos[site_id][ev.code] = ev.payload or ev
    end
    function handlers.AddressValidated(ev)
      -- Do not store PII on AO; only track proof that validation happened.
      astate.address_validations = astate.address_validations or {}
      local subj = ev.subject or "_anon"
      astate.address_validations[subj] = { ts = os.time(), siteId = site_of(ev) }
    end
    
    -- Orders / payments -------------------------------------------------------
    function handlers.OrderCreated(ev)
      cstate.orders = cstate.orders or {}
      cstate.orders[ev.orderId] = {
        siteId = site_of(ev),
        amount = ev.totalAmount or ev.amount,
        currency = ev.currency,
        items = ev.items or {},
        status = ev.status or "pending",
        customerRef = ev.customerRef or ev.customerId,
        updatedAt = os.time(),
      }
    end
    
    function handlers.OrderStatusUpdated(ev)
      cstate.orders = cstate.orders or {}
      local ord = cstate.orders[ev.orderId] or { siteId = site_of(ev) }
      ord.status = ev.status or ord.status
      ord.updatedAt = os.time()
      cstate.orders[ev.orderId] = ord
    end
    
    function handlers.PaymentStatusChanged(ev)
      cstate.payments = cstate.payments or {}
      cstate.payments[ev.paymentId] = cstate.payments[ev.paymentId] or {}
      local p = cstate.payments[ev.paymentId]
      p.status = ev.status or p.status
      p.providerStatus = ev.providerStatus or p.providerStatus
      p.orderId = ev.orderId or p.orderId
      p.siteId = site_of(ev) or p.siteId
      p.updatedAt = os.time()
    end
    
    function handlers.PaymentIntentCreated(ev)
      cstate.payments = cstate.payments or {}
      cstate.payments[ev.paymentId] = {
        status = ev.status or "requires_capture",
        amount = ev.amount,
        currency = ev.currency,
        orderId = ev.orderId,
        provider = ev.provider,
        siteId = site_of(ev),
        providerPaymentId = ev.providerPaymentId,
        updatedAt = os.time(),
      }
    end
    
    function handlers.PaymentDisputeEvidence(ev)
      cstate.payments = cstate.payments or {}
      local p = cstate.payments[ev.paymentId] or {}
      p.status = ev.status or p.status or "disputed"
      p.reason = ev.reason or p.reason
      p.provider = ev.provider or p.provider
      p.updatedAt = os.time()
      cstate.payments[ev.paymentId] = p
    end
    
    function handlers.PaymentVoided(ev)
      cstate.payments = cstate.payments or {}
      local p = cstate.payments[ev.paymentId] or {}
      p.status = ev.status or "voided"
      p.orderId = ev.orderId or p.orderId
      p.updatedAt = os.time()
      cstate.payments[ev.paymentId] = p
    end
    
    function handlers.IssueRefund(ev)
      cstate.payments = cstate.payments or {}
      local p = cstate.payments[ev.paymentId] or {}
      p.status = ev.status or "refunded"
      p.refundAmount = ev.amount or p.refundAmount
      p.orderId = ev.orderId or p.orderId
      p.updatedAt = os.time()
      cstate.payments[ev.paymentId] = p
    end
    
    -- Logistics ---------------------------------------------------------------
    function handlers.ShipmentUpdated(ev)
      local sh = cstate.shipments[ev.shipmentId] or {}
      sh.status = ev.status or sh.status
      sh.tracking = ev.tracking or sh.tracking
      sh.carrier = ev.carrier or sh.carrier
      sh.labelUrl = ev.labelUrl or sh.labelUrl
      sh.eta = ev.eta or sh.eta
      sh.orderId = ev.orderId or sh.orderId
      sh.updatedAt = os.time()
      cstate.shipments[ev.shipmentId] = sh
    end
    
    function handlers.ShippingLabelCreated(ev)
      handlers.ShipmentUpdated(ev)
    end
    
    function handlers.ShipmentTrackingUpdated(ev)
      handlers.ShipmentUpdated(ev)
    end
    
    function handlers.ReturnUpdated(ev)
      local r = cstate.returns[ev.returnId] or {}
      r.status = ev.status or r.status
      r.reason = ev.reason or r.reason
      r.orderId = ev.orderId or r.orderId
      r.updatedAt = os.time()
      cstate.returns[ev.returnId] = r
    end
    
    -- Registry / access -------------------------------------------------------
    function handlers.DomainLinked(ev)
      rstate.domains[ev.host] = site_of(ev)
    end
    
    function handlers.EntitlementGranted(ev)
      astate.entitlements[k(ev.subject, ev.asset)] = ev.policy
    end
    
    function handlers.KeyRotated(ev)
      rstate.keys = rstate.keys or {}
      rstate.keys[site_of(ev) or "_global"] = {
        version = ev.keyVersion,
        ref = ev.keyRef,
        rotatedAt = ev.rotatedAt or os.time(),
      }
    end
    
    function handlers.SubscriptionCreated(ev)
      cstate.subscriptions = cstate.subscriptions or {}
      cstate.subscriptions[ev.subscriptionId] = {
        customerId = ev.customerId,
        planId = ev.planId,
        status = ev.status or "active",
        siteId = site_of(ev),
        createdAt = ev.createdAt or os.time(),
      }
    end
    
    function handlers.SubscriptionStatusUpdated(ev)
      cstate.subscriptions = cstate.subscriptions or {}
      local sub = cstate.subscriptions[ev.subscriptionId] or { siteId = site_of(ev) }
      sub.status = ev.status or sub.status
      sub.updatedAt = os.time()
      cstate.subscriptions[ev.subscriptionId] = sub
    end
    
    function handlers.ReceiptCreated(ev)
      astate.receipts = astate.receipts or {}
      table.insert(astate.receipts, {
        receiptId = ev.receiptId,
        siteId = site_of(ev),
        ts = ev.ts or os.time(),
      })
    end
    
    function handlers.SessionStarted(ev)
      astate.sessions = astate.sessions or {}
      astate.sessions[ev.sessionHash] = {
        subject = ev.subject,
        exp = ev.exp,
      }
    end
    
    function handlers.SessionRevoked(ev)
      if astate.sessions then
        astate.sessions[ev.sessionHash] = nil
      end
    end
    
    function handlers.CouponApplied(ev)
      cstate.orders = cstate.orders or {}
      local ord = cstate.orders[ev.orderId] or { siteId = site_of(ev) }
      ord.coupon = ev.code or ord.coupon
      ord.discount = ev.discount or ord.discount
      ord.updatedAt = os.time()
      cstate.orders[ev.orderId] = ord
    end
    
    function handlers.CouponRemoved(ev)
      if cstate.orders and cstate.orders[ev.orderId] then
        local ord = cstate.orders[ev.orderId]
        ord.coupon = nil
        ord.discount = nil
        ord.updatedAt = os.time()
      end
    end
    
    function handlers.FormSubmitted(ev)
      sstate.forms = sstate.forms or {}
      local site_id = site_of(ev)
      sstate.forms[site_id] = sstate.forms[site_id] or {}
      table.insert(sstate.forms[site_id], ev)
    end
    
    function handlers.FormWebhook(ev)
      handlers.FormSubmitted(ev)
    end
    
    function handlers.GatewayFlagged(ev)
      rstate.resolver_flags = rstate.resolver_flags or {}
      rstate.resolver_flags[ev.gatewayId] = {
        flag = ev.flag,
        reason = ev.reason,
        ts = ev.ts or os.time(),
      }
    end
    
    -- Minimal PII scrubber before writing immutable exports
    local function apply(ev)
      if not ev then
        metrics.inc "ao_ingest_apply_failed"
        return false, "missing_event"
      end
      local key = ev.action or ev.type
      if not key then
        metrics.inc "ao_ingest_apply_failed"
        return false, "missing_action"
      end
      local fn = handlers[key]
      if not fn then
        metrics.inc "ao_ingest_apply_failed"
        return false, "unknown_action"
      end
      local ok, err = pcall(fn, ev)
      if not ok then
        metrics.inc "ao_ingest_apply_failed"
        return false, err or "handler_error"
      end
      local ts = event_ts(ev)
      if ts then
        metrics.gauge("ao_outbox_lag_seconds", math.max(0, os.time() - ts))
      end
      metrics.inc "ao_ingest_apply_ok"
      export.write(ev)
      return true
    end
    
    return {
      apply = apply,
    }
    ]====], "ao.ingest.apply")
      if not loaded then error(err) end
      local ret = loaded()
      if ret ~= nil then return ret end
    end
    
    return require("ao.registry.process")
    
  end
  
  _init()
  return {}
end
_G.package.loaded[".registry"] = _loaded_mod_registry()
  require(".registry")

  -- call evaluate from handlers passing env
  msg.reply =
      function(replyMsg)
        replyMsg.Target = msg["Reply-To"] or (replyMsg.Target or msg.From)
        replyMsg["X-Reference"] = msg["X-Reference"] or msg.Reference
        replyMsg["X-Origin"] = msg["X-Origin"] or nil

        return ao.send(replyMsg)
      end

  msg.forward =
      function(target, forwardMsg)
        -- Clone the message and add forwardMsg tags
        local newMsg = ao.sanitize(msg)
        forwardMsg = forwardMsg or {}

        for k, v in pairs(forwardMsg) do
          newMsg[k] = v
        end

        -- Set forward-specific tags
        newMsg.Target = target
        newMsg["Reply-To"] = msg["Reply-To"] or msg.From
        newMsg["X-Reference"] = msg["X-Reference"] or msg.Reference
        newMsg["X-Origin"] = msg["X-Origin"] or msg.From
        -- clear functions
        newMsg.reply = nil
        newMsg.forward = nil

        ao.send(newMsg)
      end

  local co = coroutine.create(
    function()
      return pcall(Handlers.evaluate, msg, env)
    end
  )
  local _, status, result = coroutine.resume(co)

  -- Make sure we have a reference to the coroutine if it will wake up.
  -- Simultaneously, prune any dead coroutines so that they can be
  -- freed by the garbage collector.
  table.insert(Handlers.coroutines, co)
  for i, x in ipairs(Handlers.coroutines) do
    if coroutine.status(x) == "dead" then
      table.remove(Handlers.coroutines, i)
    end
  end

  if not status then
    if (msg.Action == "Eval") then
      table.insert(Errors, result)
      local printData = table.concat(HANDLER_PRINT_LOGS, "\n")
      return { Error = printData .. '\n\n' .. Colors.red .. 'error:\n' .. Colors.reset .. result }
    end
    --table.insert(Errors, result)
    --ao.outbox.Output.data = ""
    if msg.Action then
      print(Colors.red .. "Error" .. Colors.gray .. " handling message with Action = " .. msg.Action .. Colors.reset)
    else
      print(Colors.red .. "Error" .. Colors.gray .. " handling message " .. Colors.reset)
    end
    print(Colors.green .. result .. Colors.reset)
    print("\n" .. Colors.gray .. removeLastThreeLines(debug.traceback()) .. Colors.reset)
    local printData = table.concat(HANDLER_PRINT_LOGS, "\n")
    return ao.result({ Error = printData .. '\n\n' .. Colors.red .. 'error:\n' .. Colors.reset .. result, Messages = {}, Spawns = {}, Assignments = {} })
  end

  if msg.Action == "Eval" then
    local response = ao.result({
      Output = {
        data = table.concat(HANDLER_PRINT_LOGS, "\n"),
        prompt = Prompt(),
        test = Dump(HANDLER_PRINT_LOGS)
      }
    })
    HANDLER_PRINT_LOGS = {} -- clear logs
    ao.Nonce = msg.Nonce
    return response
  elseif msg.Tags.Type == "Process" and Owner == msg.From then
    local response = ao.result({
      Output = {
        data = table.concat(HANDLER_PRINT_LOGS, "\n"),
        prompt = Prompt(),
        print = true
      }
    })
    HANDLER_PRINT_LOGS = {} -- clear logs
    ao.Nonce = msg.Nonce
    return response

    -- local response = nil

    -- -- detect if there was any output from the boot loader call
    -- for _, value in pairs(HANDLER_PRINT_LOGS) do
    --   if value ~= "" then
    --     -- there was output from the Boot Loader eval so we want to print it
    --     response = ao.result({ Output = { data = table.concat(HANDLER_PRINT_LOGS, "\n"), prompt = Prompt(), print = true } })
    --     break
    --   end
    -- end

    -- if response == nil then
    --   -- there was no output from the Boot Loader eval, so we shouldn't print it
    --   response = ao.result({ Output = { data = "", prompt = Prompt() } })
    -- end

    -- HANDLER_PRINT_LOGS = {} -- clear logs
    -- return response
  else
    local response = ao.result({ Output = { data = table.concat(HANDLER_PRINT_LOGS, "\n"), prompt = Prompt(), print = true } })
    HANDLER_PRINT_LOGS = {} -- clear logs
    ao.Nonce = msg.Nonce
    return response
  end
end

-- Install latest apm
apm = require('.apm')

-- injected resolver bundle (preload-only)
-- bundled AO process (resolver)

package.preload["ao.shared.a11y"] = function()
  local loaded, err = load([====[-- Simple accessibility & performance lint for page content blocks.

local A11y = {}

local function warn(list, msg)
  table.insert(list, msg)
end

-- Validate a single block; return warnings appended to provided list.
local function validate_block(block, warnings, last_heading_level)
  local typ = block.type or block.kind
  if typ == "image" or typ == "hero" then
    if not block.alt or block.alt == "" then
      warn(warnings, "Image block missing alt text")
    end
  elseif typ == "link" then
    if not block.text or block.text == "" then
      warn(warnings, "Link block missing text")
    end
    if block.href and block.href:match "^javascript:" then
      warn(warnings, "Link uses javascript: URI, avoid for accessibility")
    end
  elseif typ == "heading" then
    local level = tonumber(block.level or block.depth or 0) or 0
    if level < 1 or level > 6 then
      warn(warnings, "Heading level must be 1-6")
    elseif last_heading_level and level > last_heading_level + 1 then
      warn(
        warnings,
        string.format("Heading level skips from h%d to h%d", last_heading_level, level)
      )
    end
    return level
  end
  return last_heading_level
end

---Validate a page content table (expects blocks array).
-- Returns ok:boolean, warnings:table
function A11y.validate_page(content)
  local warnings = {}
  if not content or type(content) ~= "table" then
    return true, warnings
  end
  local blocks = content.blocks or {}
  local last_heading_level = nil
  for _, block in ipairs(blocks) do
    last_heading_level = validate_block(block, warnings, last_heading_level)
  end
  return #warnings == 0, warnings
end

return A11y
]====], "ao.shared.a11y")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.analytics"] = function()
  local loaded, err = load([====[-- Simple analytics/risk/subscription helpers (secretless, future-proof).
-- Counts via metrics and optionally appends NDJSON to METRICS_LOG.

local json_ok, json = pcall(require, "cjson.safe")
if not json_ok then
  json_ok, json = pcall(require, "cjson")
end
local metrics = require "ao.shared.metrics"

local Analytics = {}

local function encode_json(value)
  if not (json_ok and json and json.encode) then
    return nil
  end
  local ok, encoded = pcall(json.encode, value)
  if not ok then
    return nil
  end
  return encoded
end

local function write_log(ev)
  local path = os.getenv "METRICS_LOG"
  if not path or path == "" then
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  ev.ts = os.date "!%Y-%m-%dT%H:%M:%SZ"
  local payload = encode_json(ev)
  if not payload then
    f:close()
    return
  end
  f:write(payload)
  f:write "\n"
  f:close()
end

function Analytics.page_view(site, path, locale)
  metrics.inc "ao_page_view"
  write_log { event = "page_view", site = site, path = path, locale = locale }
end

function Analytics.product_view(site, sku, locale)
  metrics.inc "ao_product_view"
  write_log { event = "product_view", site = site, sku = sku, locale = locale }
end

-- risk event: attrs should already be hashed/obfuscated
function Analytics.risk_event(kind, attrs)
  metrics.inc "ao_risk_event"
  local ev = attrs or {}
  ev.event = kind or "risk"
  write_log(ev)
end

function Analytics.subscription_start(site, plan, attrs)
  metrics.inc "ao_subscription_start"
  local ev = attrs or {}
  ev.event = "subscription_start"
  ev.site = site
  ev.plan = plan
  write_log(ev)
end

function Analytics.subscription_cancel(site, plan, reason, attrs)
  metrics.inc "ao_subscription_cancel"
  metrics.inc "ao_subscription_churn"
  local ev = attrs or {}
  ev.event = "subscription_cancel"
  ev.site = site
  ev.plan = plan
  ev.reason = reason
  write_log(ev)
end

return Analytics
]====], "ao.shared.analytics")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.arweave"] = function()
  local loaded, err = load([====[-- Arweave adapter for publish flow.
-- Default mode: file-backed mock under arweave/snapshots (deterministic, hash checked).
-- If ARWEAVE_MODE=mock (default), nothing leaves the machine.

local Ar = {}

local counter = 0
local manifests = {}

local MODE = os.getenv "ARWEAVE_MODE" or "mock"
local SNAPSHOT_DIR = os.getenv "ARWEAVE_STORAGE_DIR" or "arweave/snapshots"
local REQUEST_LOG = os.getenv "ARWEAVE_REQUEST_LOG" or "arweave/manifests"
local ENDPOINT = os.getenv "ARWEAVE_HTTP_ENDPOINT"
local API_KEY = os.getenv "ARWEAVE_HTTP_API_KEY"
local SIGNER = os.getenv "ARWEAVE_HTTP_SIGNER" -- path to key or wallet JSON
local HTTP_TIMEOUT = tonumber(os.getenv "ARWEAVE_HTTP_TIMEOUT" or "10")
local HTTP_REAL = os.getenv "ARWEAVE_HTTP_REAL" == "1"
local HTTP_SIGNER_HEADER = os.getenv "ARWEAVE_HTTP_SIGNER_HEADER" or "X-Arweave-Signer"
local HTTP_RETRIES = tonumber(os.getenv "ARWEAVE_HTTP_RETRIES" or "3")
local HTTP_BACKOFF_MS = tonumber(os.getenv "ARWEAVE_HTTP_BACKOFF_MS" or "200")
local MAX_MANIFEST_BYTES = tonumber(os.getenv "ARWEAVE_MAX_MANIFEST_BYTES" or "262144") -- 256 KiB
local HTTP_MAX_BODY = tonumber(os.getenv "ARWEAVE_HTTP_MAX_BODY" or "1048576") -- 1 MiB
local EXPECT_RESPONSE_HASH = os.getenv "ARWEAVE_EXPECT_RESPONSE_HASH"
local FORCE_ERROR = os.getenv "ARWEAVE_FORCE_ERROR" == "1"
local RESPONSE_PATTERN = os.getenv "ARWEAVE_RESPONSE_PATTERN" or '^%s*%{"'
local _, cjson_safe = pcall(require, "cjson.safe")
local cjson = cjson_safe or require "cjson" -- required dependency
local schema = require "ao.shared.schema"
local openssl_ok, openssl = pcall(require, "openssl")
local sodium_ok, sodium = pcall(require, "sodium")
if not sodium_ok then
  sodium_ok, sodium = pcall(require, "luasodium")
end

local function next_tx()
  counter = counter + 1
  return string.format("mock-tx-%06d", counter)
end

local function ensure_dir(path)
  os.execute(string.format('mkdir -p "%s"', path))
end

local function bin_to_hex(bytes)
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function sha256(str)
  if openssl_ok and openssl.digest then
    local d = openssl.digest.new "sha256"
    d:update(str)
    return bin_to_hex(d:final())
  elseif sodium_ok and sodium.crypto_hash_sha256 then
    return bin_to_hex(sodium.crypto_hash_sha256(str))
  else
    local r = io.popen(
      'printf %s "'
        .. str:gsub('"', '\\"')
        .. '" | openssl dgst -sha256 -binary 2>/dev/null | xxd -p',
      "r"
    )
    if r then
      local out = r:read "*a" or ""
      r:close()
      out = out:gsub("%s+", "")
      if #out > 0 then
        return out
      end
    end
  end
  return nil
end

local function file_sha256(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read "*a"
  f:close()
  return sha256(content)
end

local function has_curl()
  local ok = os.execute "command -v curl >/dev/null 2>&1"
  return ok == true or ok == 0
end

local function http_post(serialized, tx)
  ensure_dir(REQUEST_LOG)
  local response_path = string.format("%s/%s-response.json", REQUEST_LOG, tx)
  local auth_header = API_KEY and (' -H "Authorization: Bearer ' .. API_KEY .. '"') or ""
  local signer_header = SIGNER and (' -H "' .. HTTP_SIGNER_HEADER .. ": " .. SIGNER .. '"') or ""
  local curl_fmt = table.concat({
    'echo %q | curl -s -o "%s" -w "%%{http_code}"',
    '-H "Content-Type: application/json"%s%s',
    '--max-time %d -X POST "%s" --data-binary @-',
  }, " ")
  local status
  for attempt = 1, HTTP_RETRIES do
    local cmd = string.format(
      curl_fmt,
      serialized,
      response_path,
      auth_header,
      signer_header,
      HTTP_TIMEOUT,
      ENDPOINT or ""
    )
    local pipe = io.popen(cmd, "r")
    if pipe then
      status = pipe:read "*a"
      pipe:close()
      status = status and status:match "(%d+)"
      if status then
        status = tonumber(status)
      end
      if status and status < 500 then
        break
      end
    end
    if attempt < HTTP_RETRIES then
      local jitter = math.random() * 0.5 + 0.75 -- 0.75-1.25x
      os.execute(string.format("sleep %.3f", (HTTP_BACKOFF_MS * jitter) / 1000))
    end
  end
  return status, response_path
end

local function signer_exists()
  if not SIGNER or SIGNER == "" then
    return true
  end
  local f = io.open(SIGNER, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function fallback_checksum(str)
  local sum = 0
  for i = 1, #str do
    sum = (sum + string.byte(str, i)) % 0xFFFFFFFF
  end
  return string.format("%08x", sum)
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function sorted_keys(tbl)
  local keys = {}
  for k in pairs(tbl) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function json_encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    return value and "true" or "false"
  end
  if t == "number" then
    return tostring(value)
  end
  if t == "string" then
    return string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, json_encode(v))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for _, k in ipairs(sorted_keys(value)) do
        local v = value[k]
        table.insert(parts, string.format("%q:%s", k, json_encode(v)))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return '"<unsupported>"'
end

local function persist_manifest(tx, content)
  ensure_dir(SNAPSHOT_DIR)
  local path = SNAPSHOT_DIR .. "/" .. tx .. ".json"
  local f = io.open(path, "w")
  if f then
    f:write(content)
    f:close()
  end
end

-- Stores a snapshot payload and returns a manifest transaction id and hash.
function Ar.put_snapshot(payload)
  local tx = next_tx()
  local serialized = json_encode(payload)
  if MAX_MANIFEST_BYTES and #serialized > MAX_MANIFEST_BYTES then
    return nil, "too_large"
  end
  local hash = sha256(serialized) or fallback_checksum(serialized)

  manifests[tx] = {
    payload = payload,
    hash = hash,
    storedAt = os.date "!%Y-%m-%dT%H:%M:%SZ",
  }

  if MODE == "mock" then
    persist_manifest(tx, serialized)
  end

  return tx, hash
end

function Ar.get_snapshot(tx)
  return manifests[tx]
end

function Ar.verify_snapshot(tx, expected_hash)
  local m = manifests[tx]
  if not m then
    return false, "not_found"
  end
  if expected_hash and m.hash ~= expected_hash then
    return false, "hash_mismatch"
  end
  return true
end

-- HTTP mode placeholder: log outbound request; real network disabled here.
local function log_request(tx, payload, hash)
  ensure_dir(REQUEST_LOG)
  local path = string.format("%s/%s-request.json", REQUEST_LOG, tx)
  local f = io.open(path, "w")
  if f then
    f:write(json_encode { tx = tx, hash = hash, payload = payload, mode = MODE })
    f:close()
  end
end

if MODE == "http" then
  -- Simulated HTTP call: writes request + simulated response status to manifests log.
  -- Still offline/off-chain; safe for local runs.
  function Ar.put_snapshot(payload)
    local tx = next_tx()
    local serialized = json_encode(payload)
    if MAX_MANIFEST_BYTES and #serialized > MAX_MANIFEST_BYTES then
      return nil, "too_large"
    end
    local hash = sha256(serialized) or fallback_checksum(serialized)
    local httpStatus, response_path
    if FORCE_ERROR then
      httpStatus = 500
    elseif HTTP_REAL and ENDPOINT and has_curl() and os.getenv "ARWEAVE_HTTP_DRYRUN" ~= "1" then
      if not signer_exists() then
        log_request(tx, {
          endpoint = ENDPOINT or "<missing-endpoint>",
          apiKey = API_KEY and "<redacted>",
          signer = SIGNER or "<missing>",
          timeout = HTTP_TIMEOUT,
          body = payload,
          simulated = true,
          error = "signer_missing",
        }, hash)
        return tx, hash
      end
      httpStatus, response_path = http_post(serialized, tx)
    else
      -- offline simulated response body so schema validation/path logic still runs
      ensure_dir(REQUEST_LOG)
      response_path = string.format("%s/%s-response.json", REQUEST_LOG, tx)
      local body = os.getenv "ARWEAVE_HTTP_SIM_BODY"
        or string.format('{"status":"ok","tx":"%s"}', tx)
      local f = io.open(response_path, "w")
      if f then
        f:write(body)
        f:close()
      end
      httpStatus = tonumber(os.getenv "ARWEAVE_HTTP_SIM_STATUS" or "200")
    end
    local signerHash = SIGNER and file_sha256(SIGNER) or nil
    if httpStatus and httpStatus >= 400 then
      log_request(tx, { error = "http_error", status = httpStatus })
      return nil, "http_error"
    end
    if response_path then
      local f = io.open(response_path, "r")
      if f then
        local body = f:read "*a" or ""
        f:close()
        if #body == 0 then
          log_request(tx, { warning = "empty_response" })
        elseif HTTP_MAX_BODY and #body > HTTP_MAX_BODY then
          log_request(tx, { error = "response_too_large", size = #body })
          return nil, "http_response_too_large"
        else
          if RESPONSE_PATTERN and not body:match(RESPONSE_PATTERN) then
            log_request(tx, { warning = "response_unexpected_pattern" })
            return nil, "http_response_invalid"
          end
          local parsed = cjson.decode(body)
          if not parsed then
            return nil, "http_response_invalid_json"
          end
          local ok_schema, err_schema = schema.validate("arweaveResponse", parsed)
          if not ok_schema then
            log_request(tx, { warning = "response_schema_invalid", errors = err_schema })
            return nil, "http_response_schema_invalid"
          end
          local resp_hash = sha256(body)
          if not resp_hash then
            log_request(tx, { warning = "response_hash_failed" })
          else
            log_request(tx, { responseHash = resp_hash })
            if EXPECT_RESPONSE_HASH and resp_hash ~= EXPECT_RESPONSE_HASH then
              return nil, "response_hash_mismatch"
            end
          end
        end
      end
    end
    log_request(tx, {
      endpoint = ENDPOINT or "<missing-endpoint>",
      apiKey = API_KEY and "<redacted>",
      signer = SIGNER and "<redacted>",
      signerHash = signerHash,
      timeout = HTTP_TIMEOUT,
      body = payload,
      simulated = not HTTP_REAL,
      httpStatus = httpStatus,
      responsePath = response_path,
    }, hash)
    return tx, hash
  end
end

-- Expose for tests
Ar._manifests = manifests

return Ar
]====], "ao.shared.arweave")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.assets"] = function()
  local loaded, err = load([====[-- Asset helpers: generate responsive variants and minimal CDN invalidation hooks.

local Assets = {}

local DEFAULT_SIZES = { 320, 640, 960, 1280, 1920 }
local DEFAULT_FORMATS = { "avif", "webp", "jpg" }

local function normalize_formats(formats)
  if not formats or #formats == 0 then
    return DEFAULT_FORMATS
  end
  local out = {}
  local seen = {}
  for _, f in ipairs(formats) do
    local fmt = tostring(f):lower()
    if not seen[fmt] then
      table.insert(out, fmt)
      seen[fmt] = true
    end
  end
  return out
end

local function normalize_sizes(sizes)
  if not sizes or #sizes == 0 then
    return DEFAULT_SIZES
  end
  local out = {}
  for _, s in ipairs(sizes) do
    local n = tonumber(s)
    if n and n > 0 then
      table.insert(out, math.floor(n))
    end
  end
  table.sort(out)
  return out
end

local function build_url(base_url, path)
  if not base_url or base_url == "" then
    return path
  end
  if base_url:sub(-1) == "/" then
    base_url = base_url:sub(1, -2)
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return base_url .. path
end

---Generate responsive variants for an image using a deterministic URL pattern.
-- The pattern is: {base}/{width}w/{basename}.{format}
function Assets.build_image_variants(src, opts)
  opts = opts or {}
  local sizes = normalize_sizes(opts.sizes)
  local formats = normalize_formats(opts.formats)
  local base_url = opts.base_url or os.getenv "ASSET_BASE_URL" or "/assets"

  local basename = src:gsub("^.*/", "")
  local variants = {}
  local srcset = {}

  for _, fmt in ipairs(formats) do
    srcset[fmt] = {}
    for _, w in ipairs(sizes) do
      local path = string.format("%dw/%s.%s", w, basename, fmt)
      local url = build_url(base_url, path)
      table.insert(srcset[fmt], string.format("%s %dw", url, w))
      table.insert(variants, { width = w, format = fmt, url = url })
    end
    srcset[fmt] = table.concat(srcset[fmt], ", ")
  end

  return {
    src = build_url(base_url, basename),
    sizes = sizes,
    formats = formats,
    variants = variants,
    srcset = srcset,
    loading = "lazy",
    placeholder = "blur",
  }
end

-- Lightweight CDN purge hook; caller passes relative or absolute paths.
function Assets.cdn_invalidate(paths)
  if type(paths) ~= "table" or #paths == 0 then
    return { purged = 0 }
  end
  local purged = 0
  local endpoint = os.getenv "CDN_PURGE_URL"
  for _, path in ipairs(paths) do
    if endpoint and endpoint ~= "" then
      os.execute(string.format("curl -s -X PURGE %s%s >/dev/null 2>&1", endpoint, path))
    else
      -- fallback: no-op echo
      os.execute(string.format('echo "PURGE %s" >/dev/null', path))
    end
    purged = purged + 1
  end
  return { purged = purged }
end

return Assets
]====], "ao.shared.assets")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.audit"] = function()
  local loaded, err = load([====[-- Append-only audit stub for local testing.

local Audit = {}
local records = {}
local LOG_DIR = os.getenv "AUDIT_LOG_DIR" or "arweave/manifests"
local MAX_IN_MEMORY = tonumber(os.getenv "AUDIT_MAX_RECORDS" or "1000")
local FORMAT = os.getenv "AUDIT_FORMAT" or "line" -- line | ndjson
local ROTATE_MAX = tonumber(os.getenv "AUDIT_ROTATE_MAX" or "1048576") -- bytes
local RETAIN_FILES = tonumber(os.getenv "AUDIT_RETAIN_FILES" or "10") -- number of rotated files per stream

local function ensure_dir(path)
  os.execute(string.format('mkdir -p "%s"', path))
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function json_encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  end
  if t == "boolean" then
    return value and "true" or "false"
  end
  if t == "number" then
    return tostring(value)
  end
  if t == "string" then
    return string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local parts = {}
      for _, v in ipairs(value) do
        table.insert(parts, json_encode(v))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      for k, v in pairs(value) do
        table.insert(parts, string.format("%q:%s", k, json_encode(v)))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return '"<unsupported>"'
end

local lfs_ok, lfs = pcall(require, "lfs")

local function rotate_if_needed(path)
  if not path or path == "" then
    return
  end
  local f = io.open(path, "r")
  if not f then
    return
  end
  local content = f:read "*a"
  f:close()
  if #content >= ROTATE_MAX then
    local rotated = path .. "." .. os.date "!%Y%m%d%H%M%S"
    os.rename(path, rotated)
    if lfs_ok then
      -- retention
      local dir, file = path:match "(.+)/([^/]+)$"
      local prefix = file .. "."
      local rotated_files = {}
      for rfile in lfs.dir(dir) do
        if rfile:find("^" .. prefix) then
          table.insert(rotated_files, dir .. "/" .. rfile)
        end
      end
      table.sort(rotated_files, function(a, b)
        return a > b
      end) -- newest first (lexicographic on timestamp suffix)
      for i = RETAIN_FILES + 1, #rotated_files do
        os.remove(rotated_files[i])
      end
    end
  end
end

function Audit.append(entry)
  if os.getenv "AUDIT_DISABLE" == "1" then
    return true
  end
  if not entry.ts then
    entry.ts = os.date "!%Y-%m-%dT%H:%M:%SZ"
  end
  table.insert(records, entry)
  if #records > MAX_IN_MEMORY then
    table.remove(records, 1)
  end
  if LOG_DIR then
    ensure_dir(LOG_DIR)
    local path = string.format("%s/audit.log", LOG_DIR)
    rotate_if_needed(path)
    local f = io.open(path, "a")
    if f then
      if FORMAT == "ndjson" then
        f:write(json_encode(entry), "\n")
      else
        f:write(tostring(entry.action or "event"), " ", json_encode(entry), "\n")
      end
      f:close()
    end
  end
end

-- Helper to record a normalized event
-- fields: process, action, requestId, actorRole, siteId, resultCode
function Audit.record(process, action, msg, resp, extra)
  local entry = {
    process = process,
    action = action,
    requestId = msg and msg["Request-Id"],
    actorRole = msg and (msg["Actor-Role"] or msg.actorRole),
    siteId = msg and (msg["Site-Id"] or msg.siteId),
    status = resp and resp.status,
    resultCode = resp and resp.code or resp and resp.status,
  }
  if extra then
    for k, v in pairs(extra) do
      entry[k] = v
    end
  end
  Audit.append(entry)
  -- optional per-process log
  if LOG_DIR and process then
    local path = string.format("%s/audit-%s.log", LOG_DIR, process)
    rotate_if_needed(path)
    local f = io.open(path, "a")
    if f then
      if FORMAT == "ndjson" then
        f:write(json_encode(entry), "\n")
      else
        f:write(tostring(entry.action or "event"), " ", json_encode(entry), "\n")
      end
      f:close()
    end
  end
end

function Audit.all()
  return records
end

function Audit.log_path()
  return LOG_DIR and (LOG_DIR .. "/audit.log") or nil
end

function Audit.process_log_path(process)
  if not LOG_DIR or not process then
    return nil
  end
  return string.format("%s/audit-%s.log", LOG_DIR, process)
end

function Audit._clear()
  records = {}
end

return Audit
]====], "ao.shared.audit")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.auth"] = function()
  local loaded, err = load([====[-- Shared auth utilities: signature verification and role checks.
-- AO environment is expected to verify signatures; here we keep role/allowlist helpers.

local jwt_ok, jwt = pcall(require, "ao.shared.jwt")
local metrics_ok, metrics = pcall(require, "ao.shared.metrics")

local Auth = {}
local os_time = os.time

local NONCE_TTL = tonumber(os.getenv "AUTH_NONCE_TTL_SECONDS" or "300")
local NONCE_MAX = tonumber(os.getenv "AUTH_NONCE_MAX_ENTRIES" or "2048")
local NONCE_SQLITE = os.getenv "AUTH_NONCE_SQLITE"
local REQUIRE_NONCE = os.getenv "AUTH_REQUIRE_NONCE" ~= "0" -- default ON
local REQUIRE_SIGNATURE = os.getenv "AUTH_REQUIRE_SIGNATURE" ~= "0" -- default ON
local REQUIRE_TS = os.getenv "AUTH_REQUIRE_TIMESTAMP" ~= "0"
local TS_DRIFT = tonumber(os.getenv "AUTH_MAX_CLOCK_SKEW" or "300")
local RL_WINDOW = tonumber(os.getenv "AUTH_RATE_LIMIT_WINDOW_SECONDS" or "60")
local RL_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_REQUESTS" or "200")
local RL_SITE_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_SITE" or "200")
local RL_CALLER_MAX = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_PER_CALLER" or "200")
local RL_MAX_BUCKETS = tonumber(os.getenv "AUTH_RATE_LIMIT_MAX_BUCKETS" or "4096")
local RL_BUCKET_TTL =
  tonumber(os.getenv "AUTH_RATE_LIMIT_BUCKET_TTL_SECONDS" or tostring(RL_WINDOW * 4))
local RL_STATE_FILE = os.getenv "AUTH_RATE_LIMIT_FILE"
local RL_SQLITE = os.getenv "AUTH_RATE_LIMIT_SQLITE"
local SIG_SECRET = os.getenv "AUTH_SIGNATURE_SECRET"
local SIG_PUBLIC = os.getenv "AUTH_SIGNATURE_PUBLIC"
local SIG_TYPE = os.getenv "AUTH_SIGNATURE_TYPE" or "hmac" -- hmac | ed25519
local JWT_SECRET = os.getenv "AUTH_JWT_HS_SECRET"
local REQUIRE_JWT = os.getenv "AUTH_REQUIRE_JWT" == "1"
local DEVICE_TOKEN = os.getenv "AUTH_DEVICE_TOKEN"
local REQUIRE_DEVICE = os.getenv "AUTH_REQUIRE_DEVICE_TOKEN" == "1"
local REJECT_PLACEHOLDERS = os.getenv "ALLOW_PLACEHOLDER_SECRETS" ~= "1"
local PLACEHOLDER_SECRETS = {
  ["changeme-jwt-hmac"] = true,
  ["changeme-outbox-hmac"] = true,
  ["changeme-trust-hmac"] = true,
  ["changeme"] = true,
  ["change-me"] = true,
}
local openssl_ok, openssl = pcall(require, "openssl")
local sodium_ok, sodium = pcall(require, "sodium")
if not sodium_ok then
  sodium_ok, sodium = pcall(require, "luasodium")
end
local ed25519_ok, ed25519 = pcall(require, "ed25519") -- pure-lua (MIT) if installed
local sqlite_ok, sqlite = pcall(require, "lsqlite3")
local SHELL_FALLBACK = os.getenv "AUTH_ALLOW_SHELL_FALLBACK" == "1" -- default now off
local json_ok, json = pcall(require, "cjson.safe")
local FLAGS_FILE = os.getenv "AUTH_RESOLVER_FLAGS_FILE" or os.getenv "AO_FLAGS_PATH"

local nonce_store = {}
local nonce_db
local nonce_db_loaded = false
local rate_store = {}
local rate_db_loaded = false
local resolver_flags = {}

-- load persisted rate store (simple CSV key,count,reset)
if RL_STATE_FILE then
  local f = io.open(RL_STATE_FILE, "r")
  if f then
    for line in f:lines() do
      local key, count, reset = line:match "^([^,]+),(%d+),(%d+)"
      if key and count and reset then
        rate_store[key] = { count = tonumber(count), reset = tonumber(reset) }
      end
    end
    f:close()
  end
end

local SIGNATURE_EXCLUDE_KEYS = {
  Signature = true,
  signature = true,
  ["Signature-Ref"] = true,
}

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

local function hex_encode(bytes)
  if not bytes then
    return nil
  end
  if openssl_ok and openssl.hex then
    return openssl.hex(bytes)
  end
  if sodium_ok then
    if sodium.to_hex then
      return sodium.to_hex(bytes)
    end
    if sodium.bin2hex then
      return sodium.bin2hex(bytes)
    end
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function sorted_pairs(tbl)
  local keys = {}
  for k in pairs(tbl) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local i = 0
  return function()
    i = i + 1
    local key = keys[i]
    if key then
      return key, tbl[key]
    end
  end
end

local function canonical_value(val)
  local t = type(val)
  if t == "table" then
    local parts = {}
    for k, v in sorted_pairs(val) do
      parts[#parts + 1] = tostring(k) .. "=" .. canonical_value(v)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    return tostring(val)
  elseif t == "string" then
    return val
  else
    return ""
  end
end

local function canonical_payload(msg)
  if type(msg) ~= "table" then
    return ""
  end
  local cleaned = {}
  for k, v in pairs(msg) do
    if not SIGNATURE_EXCLUDE_KEYS[k] then
      cleaned[k] = v
    end
  end
  return canonical_value(cleaned)
end

local function extract_bearer(msg)
  if msg.jwt then
    return msg.jwt
  end
  if msg.JWT then
    return msg.JWT
  end
  if msg.token then
    return msg.token
  end
  local authz = msg.Authorization or msg.authorization or msg.auth
  if authz and type(authz) == "string" then
    return (authz:gsub("^%s*[Bb]earer%s+", ""))
  end
end

local function placeholder_secret(secret)
  if not REJECT_PLACEHOLDERS then
    return false
  end
  if not secret or secret == "" then
    return false
  end
  local lower = tostring(secret):lower()
  if PLACEHOLDER_SECRETS[lower] then
    return true
  end
  return lower:find "change%-me" or lower:find "changeme"
end

function Auth.consume_jwt(msg)
  if REQUIRE_JWT and (not JWT_SECRET or JWT_SECRET == "") then
    return false, "jwt_secret_missing"
  end
  if not JWT_SECRET or JWT_SECRET == "" then
    return true
  end
  if placeholder_secret(JWT_SECRET) then
    return false, "placeholder_jwt_secret"
  end
  if not jwt_ok then
    return not REQUIRE_JWT, "jwt_module_missing"
  end
  local token = extract_bearer(msg)
  if not token or token == "" then
    if REQUIRE_JWT then
      return false, "missing_jwt"
    end
    return true
  end
  local ok, claims = jwt.verify_hs256(token, JWT_SECRET)
  if not ok then
    return false, claims or "jwt_invalid"
  end
  if claims.exp and os_time() > claims.exp then
    return false, "jwt_expired"
  end
  msg["Actor-Id"] = msg["Actor-Id"] or claims.sub or claims.actor
  msg["Actor-Role"] = msg["Actor-Role"] or claims.role
  msg["Tenant"] = msg["Tenant"] or claims.tenant
  msg.Nonce = msg.Nonce or claims.nonce
  msg.jwt_claims = claims
  return true
end

-- Accepts either dash or camel case field names for flexibility with gateways.
local function extract_role(msg)
  return msg["Actor-Role"] or msg.actorRole or msg.role
end

local function prune_nonces()
  local now = os_time()
  local count = 0
  for k, v in pairs(nonce_store) do
    local exp = v.exp or v
    if exp < now then
      nonce_store[k] = nil
    else
      count = count + 1
    end
  end
  if count > NONCE_MAX then
    -- drop oldest
    local oldest_key, oldest_exp
    for k, v in pairs(nonce_store) do
      local exp = v.exp or v
      if not oldest_exp or exp < oldest_exp then
        oldest_exp = exp
        oldest_key = k
      end
    end
    if oldest_key then
      nonce_store[oldest_key] = nil
    end
  end
end

local function load_nonce_db()
  if nonce_db_loaded or not NONCE_SQLITE then
    return
  end
  if not sqlite_ok then
    return false, "nonce_sqlite_missing"
  end
  nonce_db = sqlite.open(NONCE_SQLITE)
  if not nonce_db then
    return false, "nonce_sqlite_open_failed"
  end
  nonce_db:exec "CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, exp INT, rid TEXT)"
  nonce_db_loaded = true
  return true
end

local function nonce_db_get(nonce)
  if not nonce_db then
    return nil
  end
  local stmt = nonce_db:prepare "SELECT exp,rid FROM nonces WHERE nonce=?"
  stmt:bind_values(nonce)
  local row = stmt:step() == sqlite.ROW and { exp = stmt:get_value(0), rid = stmt:get_value(1) }
    or nil
  stmt:finalize()
  return row
end

local function nonce_db_put(nonce, exp, rid)
  if not nonce_db then
    return
  end
  local stmt = nonce_db:prepare "INSERT OR REPLACE INTO nonces (nonce, exp, rid) VALUES (?, ?, ?)"
  stmt:bind_values(nonce, exp, rid)
  stmt:step()
  stmt:finalize()
end

local function nonce_db_cleanup(now)
  if nonce_db then
    nonce_db:exec(string.format("DELETE FROM nonces WHERE exp < %d", now))
  end
end

function Auth.require_nonce(msg)
  prune_nonces()
  local nonce = msg.Nonce or msg.nonce
  if not nonce then
    if REQUIRE_NONCE then
      return false, "missing_nonce"
    end
    return true
  end

  local now = os_time()
  local function memo_seen(entry)
    if entry and entry.exp and entry.exp >= now then
      return entry
    end
  end

  local seen = memo_seen(nonce_store[nonce])

  if not seen and NONCE_SQLITE then
    local ok_db, err_db = load_nonce_db()
    if ok_db == false then
      return false, err_db
    end
    seen = memo_seen(nonce_db_get(nonce))
  end

  if seen then
    if seen.rid and seen.rid == msg["Request-Id"] then
      return true
    end
    return false, "replay_nonce"
  end

  local record = { exp = now + NONCE_TTL, rid = msg["Request-Id"] }
  nonce_store[nonce] = record
  if NONCE_SQLITE and nonce_db_loaded then
    nonce_db_put(nonce, record.exp, record.rid)
    nonce_db_cleanup(now)
  end
  prune_nonces()
  return true
end

local function require_timestamp(msg)
  if not REQUIRE_TS then
    return true
  end
  local ts = msg.ts or msg.timestamp or msg["X-Timestamp"]
  if not ts then
    return false, "missing_timestamp"
  end
  ts = tonumber(ts)
  if not ts then
    return false, "invalid_timestamp"
  end
  local now = os_time()
  if math.abs(now - ts) > TS_DRIFT then
    return false, "timestamp_skew"
  end
  return true
end

function Auth.require_signature(msg)
  local sig = msg.Signature or msg.signature or msg["Signature-Ref"]
  if not sig then
    if REQUIRE_SIGNATURE then
      return false, "missing_signature"
    end
    return true
  end

  local target = canonical_payload(msg)

  if SIG_TYPE == "ed25519" and SIG_PUBLIC then
    if ed25519_ok and ed25519.verify then
      local pub = assert(io.open(SIG_PUBLIC, "rb")):read "*a"
      local raw_sig = ed25519.fromhex and ed25519.fromhex(sig) or sig
      if raw_sig and ed25519.verify(raw_sig, target, pub) then
        return true
      end
    end
    if sodium_ok and sodium.crypto_sign_verify_detached then
      local pub = assert(io.open(SIG_PUBLIC, "rb")):read "*a"
      local raw_sig
      if sodium.from_hex then
        raw_sig = sodium.from_hex(sig)
      else
        local bytes = {}
        for byte in sig:gmatch "%x%x" do
          bytes[#bytes + 1] = string.char(tonumber(byte, 16))
        end
        raw_sig = table.concat(bytes)
      end
      if raw_sig and sodium.crypto_sign_verify_detached(raw_sig, target, pub) then
        return true
      end
    end
    if openssl_ok and openssl.pkey and openssl.hex then
      local pub_pem = assert(io.open(SIG_PUBLIC, "r")):read "*a"
      local pkey = openssl.pkey.read(pub_pem, true, "public")
      local raw_sig = openssl.hex(sig)
      local ok, _ = pkey:verify(raw_sig, target, "NONE")
      if ok then
        return true
      end
    end
    if SHELL_FALLBACK then
      local tmp = os.tmpname()
      local f = io.open(tmp, "w")
      if f then
        f:write(target)
        f:close()
      end
      local cmd = string.format(
        "openssl pkeyutl -verify -pubin -inkey %q -rawin -in %q -sigfile %q 2>/dev/null",
        SIG_PUBLIC,
        tmp,
        tmp .. ".sig"
      )
      local sf = io.open(tmp .. ".sig", "w")
      if sf then
        sf:write(sig)
        sf:close()
      end
      local ok = os.execute(cmd)
      os.remove(tmp)
      os.remove(tmp .. ".sig")
      if ok == true or ok == 0 then
        return true
      end
    end
    return false, "bad_signature"
  else
    if not SIG_SECRET then
      return not REQUIRE_SIGNATURE, REQUIRE_SIGNATURE and "missing_signature_secret" or nil
    end
    local function canonical_key(secret)
      if not secret then
        return nil
      end
      if #secret == 32 then
        return secret
      end
      if #secret > 32 then
        return secret:sub(1, 32)
      end
      return secret .. string.rep("\0", 32 - #secret)
    end
    if openssl_ok and openssl.hmac then
      local raw = openssl.hmac.digest("sha256", target, SIG_SECRET, true)
      if not raw then
        return false, "sig_verify_failed"
      end
      local hex = hex_encode(raw)
      if hex:lower() ~= tostring(sig):lower() then
        return false, "bad_signature"
      end
      return true
    elseif sodium_ok and sodium.crypto_auth then
      local key = canonical_key(SIG_SECRET)
      local tag = sodium.crypto_auth(target, key)
      local hex = hex_encode(tag)
      if hex:lower() ~= tostring(sig):lower() then
        return false, "bad_signature"
      end
      return true
    else
      -- Fail closed when signature verification is required but no crypto backend is available.
      return false, "sig_backend_missing"
    end
  end
end

function Auth.verify_outbox_hmac(msg)
  local secret = os.getenv "OUTBOX_HMAC_SECRET"
  if not secret or secret == "" then
    return true
  end
  if placeholder_secret(secret) then
    return false, "placeholder_outbox_hmac_secret"
  end
  local provided = msg.hmac or msg.Hmac
  if not provided then
    return false, "missing_outbox_hmac"
  end
  local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
  if not crypto_ok then
    return false, "crypto_missing"
  end
  local payload = (msg["Site-Id"] or "")
    .. "|"
    .. (msg["Page-Id"] or msg["Order-Id"] or "")
    .. "|"
    .. (msg.Version or msg["Manifest-Tx"] or msg.Amount or "")
  local expected = crypto.hmac_sha256_hex(payload, secret)
  if not expected or expected:lower() ~= tostring(provided):lower() then
    return false, "outbox_hmac_mismatch"
  end
  return true
end

-- Optional action-aware wrapper for OUTBOX_HMAC enforcement.
-- opts.require_for: only enforce when opts.require_for[action] == true
-- opts.skip_for: skip enforcement when opts.skip_for[action] == true
function Auth.verify_outbox_hmac_for_action(msg, opts)
  opts = opts or {}
  local action = msg and msg.Action
  if type(action) ~= "string" or action == "" then
    return Auth.verify_outbox_hmac(msg)
  end

  if type(opts.require_for) == "table" then
    if not opts.require_for[action] then
      return true
    end
    return Auth.verify_outbox_hmac(msg)
  end

  if type(opts.skip_for) == "table" and opts.skip_for[action] then
    return true
  end

  return Auth.verify_outbox_hmac(msg)
end

local function rate_key(msg)
  local site = msg["Site-Id"] or "global"
  local actor = msg.Subject or msg["Actor-Id"] or msg["Actor-Role"] or "anon"
  return site .. ":" .. actor
end

local function prune_rate()
  local now = os_time()
  for k, v in pairs(rate_store) do
    if v.reset < now then
      rate_store[k] = nil
    end
  end
  if RL_BUCKET_TTL and RL_BUCKET_TTL > 0 then
    for k, v in pairs(rate_store) do
      local reset = tonumber(v.reset) or now
      if now - reset > RL_BUCKET_TTL then
        rate_store[k] = nil
      end
    end
  end
  if RL_MAX_BUCKETS and RL_MAX_BUCKETS > 0 then
    local count = 0
    local oldest_key, oldest_reset
    for k, v in pairs(rate_store) do
      count = count + 1
      local reset = tonumber(v.reset) or now
      if not oldest_reset or reset < oldest_reset then
        oldest_reset = reset
        oldest_key = k
      end
    end
    while count > RL_MAX_BUCKETS and oldest_key do
      rate_store[oldest_key] = nil
      count = count - 1
      oldest_key, oldest_reset = nil, nil
      for k, v in pairs(rate_store) do
        local reset = tonumber(v.reset) or now
        if not oldest_reset or reset < oldest_reset then
          oldest_reset = reset
          oldest_key = k
        end
      end
    end
  end
end

local function load_rate_store_sqlite()
  if not RL_SQLITE or not sqlite_ok or rate_db_loaded then
    return
  end
  Auth._db = sqlite.open(RL_SQLITE)
  Auth._db:exec "CREATE TABLE IF NOT EXISTS rate (k TEXT PRIMARY KEY, count INT, reset INT)"
  for row in Auth._db:nrows "SELECT k,count,reset FROM rate" do
    rate_store[row.k] =
      { count = tonumber(row.count) or 0, reset = tonumber(row.reset) or os_time() }
  end
  rate_db_loaded = true
end

function Auth.check_rate_limit(msg)
  load_rate_store_sqlite()
  prune_rate()
  local key = rate_key(msg)
  local now = os_time()
  local bucket = rate_store[key] or { count = 0, reset = now + RL_WINDOW }
  bucket.count = bucket.count + 1
  if bucket.reset < now then
    bucket.count = 1
    bucket.reset = now + RL_WINDOW
  end
  rate_store[key] = bucket
  if bucket.count > RL_MAX then
    if metrics_ok and metrics.counter then
      metrics.counter("ao.auth.rate_global_block", 1)
    end
    return false, "rate_limited"
  end

  -- per-site cap
  if RL_SITE_MAX and RL_SITE_MAX > 0 and msg["Site-Id"] then
    local site_key = "site:" .. msg["Site-Id"]
    local s = rate_store[site_key] or { count = 0, reset = now + RL_WINDOW }
    if s.reset < now then
      s.count = 0
      s.reset = now + RL_WINDOW
    end
    s.count = s.count + 1
    rate_store[site_key] = s
    if s.count > RL_SITE_MAX then
      if metrics_ok and metrics.counter then
        metrics.counter("ao.auth.rate_site_block", 1)
      end
      return false, "rate_limited_site"
    end
  end

  -- per-caller cap (gateway/worker)
  if RL_CALLER_MAX and RL_CALLER_MAX > 0 and msg["X-Caller"] then
    local caller_key = "caller:" .. tostring(msg["X-Caller"])
    local c = rate_store[caller_key] or { count = 0, reset = now + RL_WINDOW }
    if c.reset < now then
      c.count = 0
      c.reset = now + RL_WINDOW
    end
    c.count = c.count + 1
    rate_store[caller_key] = c
    if c.count > RL_CALLER_MAX then
      if metrics_ok and metrics.counter then
        metrics.counter("ao.auth.rate_caller_block", 1)
      end
      return false, "rate_limited_caller"
    end
  end
  if metrics_ok and metrics.gauge then
    metrics.gauge(
      "ao.auth.rate_buckets",
      (function()
        local n = 0
        for _ in pairs(rate_store) do
          n = n + 1
        end
        return n
      end)()
    )
  end
  if RL_SQLITE and sqlite_ok then
    if not Auth._db then
      Auth._db = sqlite.open(RL_SQLITE)
      Auth._db:exec "CREATE TABLE IF NOT EXISTS rate (k TEXT PRIMARY KEY, count INT, reset INT)"
    end
    local stmt = Auth._db:prepare "INSERT OR REPLACE INTO rate (k,count,reset) VALUES (?, ?, ?)"
    stmt:bind_values(key, bucket.count, bucket.reset)
    stmt:step()
    stmt:finalize()
  elseif RL_STATE_FILE then
    local f = io.open(RL_STATE_FILE, "w")
    if f then
      for rk, rv in pairs(rate_store) do
        f:write(string.format("%s,%d,%d\n", rk, rv.count, rv.reset))
      end
      f:close()
    end
  end
  return true
end

function Auth.require_role(msg, allowed_roles)
  if not allowed_roles or #allowed_roles == 0 then
    return true
  end
  local role = extract_role(msg)
  if not role then
    return false, "missing_role"
  end
  if not contains(allowed_roles, role) then
    return false, "forbidden_role"
  end
  return true
end

-- Convenience: pick allowlist by action map { action = {roles...} }
function Auth.require_role_for_action(msg, policy_table)
  local roles = policy_table[msg.Action]
  if not roles then
    return true
  end
  return Auth.require_role(msg, roles)
end

local function load_resolver_flags()
  if not FLAGS_FILE or FLAGS_FILE == "" or not json_ok then
    return
  end
  local f = io.open(FLAGS_FILE, "r")
  if not f then
    return
  end
  local tmp = {}
  for line in f:lines() do
    local obj = json.decode(line)
    if obj and obj.resolverId and obj.flag then
      tmp[obj.resolverId] = obj
    end
  end
  f:close()
  resolver_flags = tmp
end

local function check_resolver_flag(msg)
  if not FLAGS_FILE then
    return true
  end
  local rid = msg["Resolver-Id"] or msg.ResolverId or msg.resolverId or msg.resolver
  if not rid then
    return true
  end
  load_resolver_flags()
  local entry = resolver_flags[rid]
  if not entry then
    return true
  end
  if entry.flag == "blocked" then
    return false, "resolver_blocked"
  elseif entry.flag == "suspicious" then
    local action = msg.Action or ""
    if action:match "^[Gg]et" or action:match "^[Ll]ist" then
      return true
    end
    return false, "resolver_suspicious_readonly"
  end
  return true
end

local function require_device_token(msg)
  local token = msg["Device-Token"] or msg.deviceToken or msg.device_token or msg.device
  if not token or token == "" then
    if REQUIRE_DEVICE then
      return false, "missing_device_token"
    end
    return true
  end
  if DEVICE_TOKEN and DEVICE_TOKEN ~= "" then
    if token ~= DEVICE_TOKEN then
      return false, "device_token_mismatch"
    end
  end
  return true
end

-- Combined security gate used by routes
function Auth.enforce(msg)
  local ok_jwt, err_jwt = Auth.consume_jwt(msg)
  if not ok_jwt then
    return false, err_jwt
  end
  local ok_nonce, err_nonce = Auth.require_nonce(msg)
  if not ok_nonce then
    return false, err_nonce
  end
  local ok_ts, err_ts = require_timestamp(msg)
  if not ok_ts then
    return false, err_ts
  end
  local ok_sig, err_sig = Auth.require_signature(msg)
  if not ok_sig then
    return false, err_sig
  end
  local ok_flag, err_flag = check_resolver_flag(msg)
  if not ok_flag then
    return false, err_flag
  end
  local ok_dev, err_dev = require_device_token(msg)
  if not ok_dev then
    return false, err_dev
  end
  local ok_rl, err_rl = Auth.check_rate_limit(msg)
  if not ok_rl then
    return false, err_rl
  end
  return true
end

return Auth
]====], "ao.shared.auth")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.codec"] = function()
  local loaded, err = load([====[-- Shared codecs and response normalization.

local Codec = {}

function Codec.ok(payload)
  return {
    status = "OK",
    payload = payload or {},
  }
end

function Codec.error(code, message, meta)
  return {
    status = "ERROR",
    code = code,
    message = message,
    meta = meta,
  }
end

function Codec.missing_tags(missing)
  return Codec.error("MISSING_TAGS", "Required tags are missing", { missing = missing })
end

function Codec.unknown_action(action)
  return Codec.error("UNKNOWN_ACTION", "Unsupported action", { action = action })
end

function Codec.not_found(resource)
  return Codec.error("NOT_FOUND", resource .. " not found", { resource = resource })
end

function Codec.not_implemented(action)
  return Codec.error("NOT_IMPLEMENTED", "Handler not implemented", { action = action })
end

return Codec
]====], "ao.shared.codec")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.export"] = function()
  local loaded, err = load([====[-- PII-scrubbing append-only export for WeaveDB/Arweave bundling.
-- Enabled when AO_WEAVEDB_EXPORT_PATH (or WRITE_OUTBOX_EXPORT_PATH) is set.

local Export = {}

local path = os.getenv "AO_WEAVEDB_EXPORT_PATH" or os.getenv "WRITE_OUTBOX_EXPORT_PATH"
local json_ok, cjson = pcall(require, "cjson.safe")

-- Keys to drop entirely to avoid persisting PII on immutable storage.
local pii_keys = {
  address = true,
  Address = true,
  line1 = true,
  line2 = true,
  city = true,
  postal = true,
  region = true,
  phone = true,
  email = true,
  subject = true,
  ["Subject"] = true,
  customerId = true,
  ["Customer-Id"] = true,
  customerRef = true,
  ["Customer-Ref"] = true,
  token = true,
  tokenHash = true,
  ["Token-Hash"] = true,
  sessionHash = true,
  ["Session-Hash"] = true,
  jwt = true,
  JWT = true,
  taxId = true,
  vatId = true,
  tracking = true,
  trackingNumber = true,
}

local function scrub(value)
  local t = type(value)
  if t ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if not pii_keys[k] then
      out[k] = scrub(v)
    end
  end
  return out
end

function Export.write(ev)
  if not path or not json_ok or not ev then
    return
  end
  local f = io.open(path, "a")
  if not f then
    return
  end
  local ok, encoded = pcall(cjson.encode, scrub(ev))
  if ok and encoded then
    f:write(encoded)
    f:write "\n"
  end
  f:close()
end

-- expose for tests
Export._scrub = scrub

return Export
]====], "ao.shared.export")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.i18n"] = function()
  local loaded, err = load([====[-- Locale helpers: detect locale from path prefixes and normalize to supported locales.

local I18n = {}

local function normalize_locale(locale)
  if not locale or locale == "" then
    return nil
  end
  return locale:lower()
end

---Detect locale prefix in a URL path and strip it.
-- @param path string (e.g. "/en/products/1")
-- @param supported table array of locales; if nil, no detection performed
-- @param default_locale string fallback locale
-- @return locale (string), stripped_path (string)
function I18n.detect_locale(path, supported, default_locale)
  local locale = normalize_locale(default_locale) or "en"
  local normalized_path = path or "/"
  if not supported or #supported == 0 or not path or path == "" then
    return locale, normalized_path
  end

  for _, candidate in ipairs(supported) do
    local lc = normalize_locale(candidate)
    local prefix = "/" .. lc
    if normalized_path == prefix then
      return lc, "/"
    end
    if normalized_path:sub(1, #prefix + 1) == prefix .. "/" then
      return lc, normalized_path:sub(#prefix + 1)
    end
  end

  return locale, normalized_path
end

return I18n
]====], "ao.shared.i18n")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.idempotency"] = function()
  local loaded, err = load([====[-- Simple in-memory idempotency registry (lookup/record) shared across AO procs.

local Idem = {}
local store = {}
local ttl = tonumber(os.getenv "IDEM_TTL_SECONDS" or "300")
local max_entries = tonumber(os.getenv "IDEM_MAX_ENTRIES" or "1024")

local function now()
  return os.time()
end

local function prune()
  local count = 0
  for k, v in pairs(store) do
    if v.expire_at and v.expire_at < now() then
      store[k] = nil
    else
      count = count + 1
    end
  end
  if count > max_entries then
    local oldest_k, oldest_ts
    for k, v in pairs(store) do
      if not oldest_ts or v.recorded_at < oldest_ts then
        oldest_ts, oldest_k = v.recorded_at, k
      end
    end
    if oldest_k then
      store[oldest_k] = nil
    end
  end
end

function Idem.lookup(request_id)
  prune()
  local v = store[request_id]
  if not v then
    return nil
  end
  return v.resp
end

-- Legacy-friendly helper used by processes; returns cached response or nil.
-- Kept separate from lookup to preserve call-sites that expect `check(...)`.
function Idem.check(request_id)
  return Idem.lookup(request_id)
end

function Idem.record(request_id, resp)
  prune()
  store[request_id] = {
    resp = resp,
    recorded_at = now(),
    expire_at = now() + ttl,
  }
end

return Idem
]====], "ao.shared.idempotency")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.ids"] = function()
  local loaded, err = load([====[-- Deterministic ID generation and namespacing helpers.
-- These keep key shapes consistent across processes.

local IDs = {}

local function normalize_path(path)
  if not path or path == "" then
    return "/"
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  -- collapse duplicate slashes (lightweight)
  path = path:gsub("//+", "/")
  return path
end

function IDs.site_key(site_id)
  return ("site:%s"):format(site_id)
end

function IDs.domain_key(host)
  return ("domain:%s"):format(host)
end

function IDs.version_key(site_id, version_id)
  return ("version:%s:%s"):format(site_id, version_id)
end

function IDs.route_key(site_id, path, locale)
  local normalized = normalize_path(path)
  if locale and locale ~= "" then
    return ("route:%s:%s:%s"):format(site_id, normalized, locale:lower())
  end
  return ("route:%s:%s"):format(site_id, normalized)
end

function IDs.page_key(site_id, page_id, version_id, locale)
  if locale and locale ~= "" then
    return ("page:%s:%s:%s:%s"):format(site_id, page_id, version_id or "active", locale:lower())
  end
  return ("page:%s:%s:%s"):format(site_id, page_id, version_id or "active")
end

function IDs.layout_key(layout_id, version_id, locale)
  if locale and locale ~= "" then
    return ("layout:%s:%s:%s"):format(layout_id, version_id or "active", locale:lower())
  end
  return ("layout:%s:%s"):format(layout_id, version_id or "active")
end

function IDs.menu_key(site_id, menu_id, version_id, locale)
  if locale and locale ~= "" then
    return ("menu:%s:%s:%s:%s"):format(site_id, menu_id, version_id or "active", locale:lower())
  end
  return ("menu:%s:%s:%s"):format(site_id, menu_id, version_id or "active")
end

function IDs.product_key(site_id, sku)
  return ("product:%s:%s"):format(site_id, sku)
end

function IDs.category_key(site_id, category_id)
  return ("category:%s:%s"):format(site_id, category_id)
end

function IDs.entitlement_key(subject, asset)
  return ("entitlement:%s:%s"):format(subject, asset)
end

return IDs
]====], "ao.shared.ids")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.jwt"] = function()
  local loaded, err = load([====[-- Minimal JWT HS256 verifier (no clock skew handling).
local crypto_ok, crypto = pcall(require, "ao.shared.crypto")
local ok_mime, mime = pcall(require, "mime")
local ok_json, cjson = pcall(require, "cjson.safe")

local Jwt = {}

local function b64url_decode(input)
  input = input:gsub("-", "+"):gsub("_", "/")
  local pad = #input % 4
  if pad > 0 then
    input = input .. string.rep("=", 4 - pad)
  end
  if ok_mime and mime.unb64 then
    return mime.unb64(input)
  end
  return nil
end

function Jwt.verify_hs256(token, secret)
  if not token or token == "" or not secret then
    return false, "missing_token"
  end
  if not crypto_ok or not crypto.hmac_sha256_hex then
    return false, "crypto_missing"
  end
  local header_b64, payload_b64, sig_b64 = token:match "([^%.]+)%.([^%.]+)%.([^%.]+)"
  if not (header_b64 and payload_b64 and sig_b64) then
    return false, "invalid_format"
  end
  local signed = header_b64 .. "." .. payload_b64
  local signature = b64url_decode(sig_b64)
  if not signature then
    return false, "bad_signature_b64"
  end
  local expected_hex = crypto.hmac_sha256_hex(signed, secret)
  local expected = expected_hex
    and expected_hex:gsub("%x%x", function(x)
      return string.char(tonumber(x, 16))
    end)
  if not expected or expected ~= signature then
    return false, "signature_mismatch"
  end
  if not ok_json then
    return false, "json_missing"
  end
  local ok_h = pcall(cjson.decode, b64url_decode(header_b64) or "")
  local ok_p, payload = pcall(cjson.decode, b64url_decode(payload_b64) or "")
  if not (ok_h and ok_p) then
    return false, "decode_failed"
  end
  return true, payload
end

return Jwt
]====], "ao.shared.jwt")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.layout_components"] = function()
  local loaded, err = load([====[-- Layout component validator for block-based layouts.

local Layout = {}

local function warn(list, msg)
  table.insert(list, msg)
end

local validators = {}

validators.hero = function(comp, warnings)
  if not comp.title or comp.title == "" then
    warn(warnings, "hero.title required")
  end
  if comp.image and (not comp.image.alt or comp.image.alt == "") then
    warn(warnings, "hero.image.alt required when image set")
  end
  if comp.image then
    comp.image.loading = comp.image.loading or "lazy"
    comp.image.placeholder = comp.image.placeholder or "blur"
  end
  if comp.cta and not comp.cta.aria_label then
    warn(warnings, "hero.cta.aria_label recommended")
  end
end

validators.grid = function(comp, warnings)
  if not comp.items or type(comp.items) ~= "table" or #comp.items == 0 then
    warn(warnings, "grid.items must be non-empty array")
  end
end

validators.carousel = function(comp, warnings)
  if not comp.slides or type(comp.slides) ~= "table" or #comp.slides == 0 then
    warn(warnings, "carousel.slides must be non-empty array")
    return
  end
  for _, slide in ipairs(comp.slides) do
    if not slide.image then
      warn(warnings, "carousel.slide.image required")
    elseif not slide.alt or slide.alt == "" then
      warn(warnings, "carousel.slide.alt required")
    end
    slide.loading = slide.loading or "lazy"
    slide.placeholder = slide.placeholder or "blur"
    if slide.cta and not slide.cta.aria_label then
      warn(warnings, "carousel.slide.cta.aria_label recommended")
    end
  end
end

validators.rich_text = function(comp, warnings)
  if not comp.body or comp.body == "" then
    warn(warnings, "rich_text.body required")
  end
end

validators.form = function(comp, warnings)
  if not comp.fields or type(comp.fields) ~= "table" or #comp.fields == 0 then
    warn(warnings, "form.fields must be non-empty array")
    return
  end
  for _, f in ipairs(comp.fields) do
    if not f.name or not f.label then
      warn(warnings, "form.field name and label required")
    end
    if f.type == "button" and not f.aria_label then
      warn(warnings, "form.button aria_label recommended")
    end
  end
end

local allowed_types = {
  hero = true,
  grid = true,
  carousel = true,
  rich_text = true,
  form = true,
}

---Validate array of components.
-- @return ok:boolean, warnings:table
function Layout.validate(components)
  local warnings = {}
  if not components or type(components) ~= "table" then
    return true, warnings
  end
  for _, comp in ipairs(components) do
    local typ = comp.type or comp.kind
    if not typ or not allowed_types[typ] then
      warn(warnings, "Unsupported component type")
    else
      local v = validators[typ]
      if v then
        v(comp, warnings)
      end
    end
  end
  return #warnings == 0, warnings
end

return Layout
]====], "ao.shared.layout_components")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.metrics"] = function()
  local loaded, err = load([====[-- Minimal metrics stub: counts and durations written to NDJSON file (mock-friendly).

local Metrics = {}

local LOG_PATH = os.getenv "METRICS_LOG" or "metrics/metrics.log"
local ENABLED = os.getenv "METRICS_ENABLED" ~= "0"
local PROM_PATH = os.getenv "METRICS_PROM_PATH"
local PROM_MODE = os.getenv "METRICS_PROM_MODE"
local FLUSH_EVERY = tonumber(os.getenv "METRICS_FLUSH_EVERY" or "0")
local FLUSH_INTERVAL = tonumber(os.getenv "METRICS_FLUSH_INTERVAL_SEC" or "0")
local counters = {}
local gauges = {}
local meta = {}
local since_flush = 0
local last_flush = os.time()
local timer = require "ao.shared.timer"
local lfs_ok, lfs = pcall(require, "lfs")
local started = false

local function register(name, kind, help)
  if not name then
    return
  end
  meta[name] = meta[name] or {}
  meta[name].type = kind or meta[name].type or "counter"
  if help then
    meta[name].help = help
  end
end

Metrics.register = register

local function ensure_dir(path)
  local dir = path:match "(.+)/[^/]+$"
  if dir then
    os.execute(string.format('mkdir -p "%s"', dir))
  end
end

local function log(event)
  if not ENABLED or not LOG_PATH then
    return
  end
  ensure_dir(LOG_PATH)
  local f = io.open(LOG_PATH, "a")
  if not f then
    return
  end
  f:write(
    string.format(
      '{"ts":"%s","event":"%s","value":%s}\n',
      os.date "!%Y-%m-%dT%H:%M:%SZ",
      event.name or "metric",
      event.value or 0
    )
  )
  f:close()
end

local function enforce_prom_mode(path)
  if not PROM_MODE or PROM_MODE == "" then
    return
  end
  os.execute(string.format('chmod %s "%s"', PROM_MODE, path))
end

function Metrics.inc(name, value)
  if os.getenv "METRICS_DISABLED" == "1" then
    return
  end
  value = value or 1
  register(name, "counter")
  counters[name] = (counters[name] or 0) + value
  log { name = name, value = counters[name] }
  since_flush = since_flush + 1
  if FLUSH_EVERY > 0 and since_flush >= FLUSH_EVERY then
    Metrics.flush_prom()
    since_flush = 0
  elseif FLUSH_EVERY == 0 then
    Metrics.flush_prom()
  end
end

function Metrics.tick()
  if os.getenv "METRICS_DISABLED" == "1" then
    return
  end
  local now = os.time()
  if FLUSH_INTERVAL > 0 and (now - last_flush) >= FLUSH_INTERVAL then
    Metrics.flush_prom()
    last_flush = now
    since_flush = 0
  end
  if FLUSH_INTERVAL > 0 then
    timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
  end
end

function Metrics.flush_prom()
  if not PROM_PATH then
    return
  end
  -- optional gauges sourced from queue files so gateway can scrape them
  local function file_lines(path)
    if not path or path == "" then
      return nil
    end
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local n = 0
    for _ in f:lines() do
      n = n + 1
    end
    f:close()
    return n
  end
  local queue_path = os.getenv "AO_QUEUE_PATH"
  local retry_path = os.getenv "AO_WEBHOOK_RETRY_PATH" or os.getenv "AO_RETRY_QUEUE_PATH"
  local breaker_flag = os.getenv "AO_PSP_BREAKER_FLAG"
  local outbox_size = file_lines(queue_path)
  local retry_size = file_lines(retry_path)
  local function file_mtime(path)
    if not lfs_ok or not path or path == "" then
      return nil
    end
    local st = lfs.attributes(path)
    return st and st.modification or nil
  end
  if outbox_size then
    register("ao_outbox_queue_size", "gauge", "Lines present in AO outbox queue file")
    gauges.ao_outbox_queue_size = outbox_size
  end
  local mtime = file_mtime(queue_path)
  if mtime then
    register("ao_outbox_lag_seconds", "gauge", "Seconds since outbox queue file was updated")
    gauges.ao_outbox_lag_seconds = math.max(0, os.time() - mtime)
  end
  if retry_size then
    register("ao_webhook_retry_queue_size", "gauge", "Pending webhook retry queue length")
    gauges.ao_webhook_retry_queue_size = retry_size
  end
  if breaker_flag then
    local bf = io.open(breaker_flag, "r")
    if bf then
      local val = bf:read "*l"
      bf:close()
      register("ao_psp_breaker_open", "gauge", "Payment provider breaker flag (1=open)")
      gauges.ao_psp_breaker_open = tonumber(val) or 0
    end
  end
  local function prom_sanitize(name)
    return (name or "metric"):gsub("[^%w_]", "_")
  end
  local function prom_name(name, kind)
    local base = prom_sanitize(name)
    if kind == "counter" and not base:match "_total$" then
      return base .. "_total"
    end
    return base
  end
  local emitted = {}
  ensure_dir(PROM_PATH)
  local f = io.open(PROM_PATH, "w")
  if not f then
    return
  end
  local function emit(name, kind, value)
    local cfg = meta[name] or { type = kind }
    local pname = prom_name(name, cfg.type or kind)
    if not emitted[pname] then
      if cfg.help then
        f:write(string.format("# HELP %s %s\n", pname, cfg.help))
      end
      f:write(string.format("# TYPE %s %s\n", pname, cfg.type or kind))
      emitted[pname] = true
    end
    f:write(string.format("%s %s\n", pname, tostring(value)))
  end
  for k, v in pairs(counters) do
    emit(k, "counter", v)
  end
  for k, v in pairs(gauges) do
    emit(k, "gauge", v)
  end
  f:close()
  enforce_prom_mode(PROM_PATH)
end

function Metrics.last_flush_ts()
  return last_flush
end

function Metrics.get(name)
  return counters[name] or 0
end

function Metrics.counter(name, value)
  Metrics.inc(name, value)
end

function Metrics.gauge(name, value)
  if os.getenv "METRICS_DISABLED" == "1" then
    return
  end
  register(name, "gauge")
  gauges[name] = value
  log { name = name, value = value }
end

function Metrics._reset()
  counters = {}
  gauges = {}
end

function Metrics.get_gauge(name)
  return gauges[name]
end

function Metrics.start_background()
  if started then
    return
  end
  started = true
  if FLUSH_INTERVAL > 0 then
    timer.start(FLUSH_INTERVAL, Metrics.flush_prom)
  end
end

-- Register common AO metrics used by ops/alerts so they get HELP/TYPE lines.
local default_meta = {
  ao_ingest_apply_ok = { type = "counter", help = "AO ingest events applied successfully" },
  ao_ingest_apply_failed = { type = "counter", help = "AO ingest apply failures" },
  ao_cache_hit = { type = "counter", help = "Cache hits served from AO cache" },
  ao_cache_miss = { type = "counter", help = "Cache misses (recompute)" },
  ao_cache_stale_hit = { type = "counter", help = "Stale cache entries served" },
  ao_cache_stale_fallback = {
    type = "counter",
    help = "Served stale cache because fresh computation failed",
  },
  ao_sitemap_export_total = { type = "counter", help = "Sitemap exports executed" },
  ao_sitemap_export_duration_seconds = {
    type = "gauge",
    help = "Duration of last sitemap export in seconds",
  },
  ao_feed_export_total = { type = "counter", help = "Catalog feed exports executed" },
  ao_feed_export_failed = { type = "counter", help = "Catalog feed export failures" },
  ao_feed_export_duration_seconds = {
    type = "gauge",
    help = "Duration of last catalog feed export in seconds",
  },
  ao_page_view_total = { type = "counter", help = "Page view events emitted" },
  ao_product_view_total = { type = "counter", help = "Product view events emitted" },
  ao_risk_event_total = { type = "counter", help = "Risk signals emitted" },
  ao_subscription_start_total = { type = "counter", help = "Subscriptions started" },
  ao_subscription_cancel_total = { type = "counter", help = "Subscriptions cancelled" },
  ao_subscription_churn_total = { type = "counter", help = "Subscription churn events" },
  ao_outbox_queue_size = {
    type = "gauge",
    help = "Lines present in AO outbox queue file (write side export)",
  },
  ao_outbox_lag_seconds = {
    type = "gauge",
    help = "Seconds since outbox queue file was last updated",
  },
  ao_webhook_retry_queue_size = {
    type = "gauge",
    help = "Webhook retry queue size from write bridge",
  },
  ao_psp_breaker_open = { type = "gauge", help = "Breaker flag value (1=open) for PSP webhooks" },
}

for name, cfg in pairs(default_meta) do
  register(name, cfg.type, cfg.help)
end

-- auto-start if interval specified
Metrics.start_background()

return Metrics
]====], "ao.shared.metrics")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.persist"] = function()
  local loaded, err = load([====[-- Persistence adapter with three tiers:
-- 1) WeaveDB export (append-only, PII-scrubbed) if AO_WEAVEDB_EXPORT_PATH is set.
-- 2) Local snapshot (PII-scrubbed) when AO_STATE_DIR is set.
-- 3) In-memory fallback.

local persist = {}

local base = os.getenv "AO_STATE_DIR"
local export_ok, export = pcall(require, "ao.shared.export")
local json_ok, cjson = pcall(require, "cjson.safe")

-- PII keys to remove before writing immutable storage.
local pii_keys = {
  address = true,
  Address = true,
  line1 = true,
  line2 = true,
  city = true,
  postal = true,
  region = true,
  phone = true,
  email = true,
  subject = true,
  ["Subject"] = true,
  customerId = true,
  ["Customer-Id"] = true,
  customerRef = true,
  ["Customer-Ref"] = true,
  token = true,
  tokenHash = true,
  ["Token-Hash"] = true,
  sessionHash = true,
  ["Session-Hash"] = true,
  jwt = true,
  JWT = true,
}

local function scrub(value)
  local t = type(value)
  if t ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    if not pii_keys[k] then
      out[k] = scrub(v)
    end
  end
  return out
end

local function path_for(ns)
  if not base then
    return nil
  end
  return base .. "/" .. ns .. ".json"
end

function persist.load(ns, default_value)
  local p = path_for(ns)
  if not p or not json_ok then
    return default_value
  end
  local f = io.open(p, "r")
  if not f then
    return default_value
  end
  local content = f:read "*a"
  f:close()
  local decoded = cjson.decode(content or "")
  if type(decoded) == "table" then
    return decoded
  end
  return default_value
end

function persist.save(ns, value)
  local p = path_for(ns)
  -- Append PII-scrubbed state snapshot to WeaveDB export (immutable)
  if export_ok and type(export.write) == "function" then
    export.write {
      kind = "state_snapshot",
      ns = ns,
      ts = os.time(),
      state = scrub(value),
    }
  end
  -- Write local snapshot (mutable, used for fast reload)
  if p and json_ok then
    local ok, encoded = pcall(cjson.encode, scrub(value))
    if not ok or not encoded then
      return
    end
    local f = io.open(p, "w")
    if not f then
      return
    end
    f:write(encoded)
    f:close()
  end
end

return persist
]====], "ao.shared.persist")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.schema"] = function()
  local loaded, err = load([====[-- Minimal JSON Schema validator with optional python/jsonschema backend.
-- If SCHEMA_VALIDATOR=python and python3+jsonschema are available,
-- uses that; otherwise falls back to the embedded validator below.

local Schema = {}
local SCHEMA_MODE = os.getenv "SCHEMA_VALIDATOR" or "auto" -- auto|python|embedded

-- Schemas embedded as Lua tables (converted from schemas/*.json)
local SCHEMAS = {
  page = {
    type = "object",
    required = { "id", "title", "blocks" },
    properties = {
      id = { type = "string" },
      title = { type = "string" },
      locale = { type = "string" },
      layoutId = { type = "string" },
      blocks = { type = "array", items = { type = "object" } },
    },
  },
  product = {
    type = "object",
    required = { "sku", "name" },
    properties = {
      sku = { type = "string" },
      name = { type = "string" },
      description = { type = "string" },
      price = { type = "number" },
      assets = { type = "array", items = { type = "string" } },
    },
  },
  route = {
    type = "object",
    required = { "siteId", "path", "pageId" },
    properties = {
      siteId = { type = "string" },
      path = { type = "string" },
      locale = { type = "string" },
      pageId = { type = "string" },
      type = { type = "string" },
    },
  },
  publish = {
    type = "object",
    required = { "publishId", "versionId", "manifestTx" },
    properties = {
      publishId = { type = "string" },
      versionId = { type = "string" },
      manifestTx = { type = "string" },
      activatedAt = { type = "string" },
      rollbackTo = { type = "string" },
    },
  },
  entitlement = {
    type = "object",
    required = { "subject", "asset" },
    properties = {
      subject = { type = "string", minLength = 1, maxLength = 128 },
      asset = { type = "string", minLength = 1, maxLength = 256 },
      policy = { type = "string", minLength = 1, maxLength = 128 },
    },
  },
  accessAsset = {
    type = "object",
    required = { "asset", "ref" },
    properties = {
      asset = { type = "string", minLength = 1, maxLength = 256, pattern = "^[%w%-%._:/]+$" },
      ref = { type = "string", minLength = 1, maxLength = 2048, pattern = "^ar://[%w%-]+$" },
      visibility = { type = "string", enum = { "protected", "public", "private" } },
    },
  },
  registryConfig = {
    type = "object",
    required = {},
    properties = {
      version = { type = "string", minLength = 1, maxLength = 128 },
      metadata = { type = "object" },
      flags = {
        type = "object",
        properties = {
          cors = { type = "boolean" },
          corsAllowlist = {
            type = "array",
            minItems = 1,
            items = { type = "string", pattern = "^https?://[%w%.-]+(:%d+)?/?$" },
          },
          immutable = { type = "boolean" },
          allowUploads = { type = "boolean" },
          ttlSeconds = { type = "number", minimum = 0, maximum = 31536000 },
          rateLimitPerMinute = { type = "number", minimum = 0, maximum = 10000 },
          maxUploadBytes = { type = "number", minimum = 0, maximum = 104857600 },
          allowAnonRead = { type = "boolean" },
          requireMfa = { type = "boolean" },
        },
      },
      region = { type = "string", enum = { "eu", "us", "apac" } },
      tier = { type = "string", enum = { "dev", "staging", "prod" } },
      codeHash = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
      buildId = { type = "string", minLength = 1, maxLength = 128 },
      signerPubKey = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
      tableProfile = {
        type = "string",
        enum = {
          "minimal",
          "core-observability",
          "auth-rbac",
          "commerce-lite",
          "monitoring-outbox",
        },
      },
      schemaManifestTx = { type = "string", pattern = "^[A-Za-z0-9_-]{10,128}$" },
      schemaHash = { type = "string", pattern = "^[a-fA-F0-9]{64}$" },
      policies = {
        type = "object",
        properties = {
          allowAnonymousRead = { type = "boolean" },
          allowAnonymousWrite = { type = "boolean" },
          auditLevel = { type = "string", enum = { "none", "basic", "full" } },
          dataResidency = { type = "string", enum = { "eu", "us", "apac", "global" } },
          piiHandling = { type = "string", enum = { "deny", "mask", "allow" } },
          allowedOrigins = {
            type = "array",
            items = { type = "string", pattern = "^https?://[%w%.-]+(:%d+)?/?$" },
            minItems = 1,
          },
          ipAllowlist = {
            type = "array",
            items = { type = "string", pattern = "^%d+%.%d+%.%d+%.%d+/%d%d?$" },
            minItems = 0,
          },
          allowedMethods = {
            type = "array",
            items = {
              type = "string",
              enum = { "GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS" },
            },
            minItems = 1,
          },
        },
      },
    },
  },
  arweaveResponse = {
    type = "object",
    required = { "status" },
    properties = {
      status = { type = "string" },
      message = { type = "string" },
      tx = { type = "string" },
    },
  },
}

local function type_of(value)
  local t = type(value)
  if t == "table" then
    local i = 0
    for _ in pairs(value) do
      i = i + 1
      if value[i] == nil then
        return "object"
      end
    end
    return "array"
  end
  return t
end

local function validate_properties(value, schema, path, errors)
  if schema.required then
    for _, req in ipairs(schema.required) do
      if value[req] == nil then
        table.insert(errors, path .. req .. " is required")
      end
    end
  end
  if schema.properties then
    for name, prop in pairs(schema.properties) do
      if value[name] ~= nil then
        local actual_type = type_of(value[name])
        if prop.type and actual_type ~= prop.type then
          table.insert(errors, path .. name .. " expected " .. prop.type .. ", got " .. actual_type)
        end
        if prop.enum then
          local ok_enum = false
          for _, ev in ipairs(prop.enum) do
            if ev == value[name] then
              ok_enum = true
            end
          end
          if not ok_enum then
            table.insert(errors, path .. name .. " not in enum")
          end
        end
        if prop.pattern and actual_type == "string" then
          if not tostring(value[name]):match(prop.pattern) then
            table.insert(errors, path .. name .. " does not match pattern")
          end
        end
        if
          prop.minLength
          and actual_type == "string"
          and #tostring(value[name]) < prop.minLength
        then
          table.insert(errors, path .. name .. " shorter than minLength")
        end
        if
          prop.maxLength
          and actual_type == "string"
          and #tostring(value[name]) > prop.maxLength
        then
          table.insert(errors, path .. name .. " longer than maxLength")
        end
        if prop.type == "array" and prop.items and value[name] ~= nil then
          for idx, item in ipairs(value[name]) do
            local item_type = type_of(item)
            if prop.items.type and item_type ~= prop.items.type then
              table.insert(
                errors,
                path
                  .. name
                  .. "["
                  .. idx
                  .. "] expected "
                  .. prop.items.type
                  .. ", got "
                  .. item_type
              )
            end
            if
              prop.items.pattern
              and type(item) == "string"
              and not tostring(item):match(prop.items.pattern)
            then
              table.insert(errors, path .. name .. "[" .. idx .. "] does not match pattern")
            end
            if prop.items.enum then
              local ok_enum = false
              for _, ev in ipairs(prop.items.enum) do
                if ev == item then
                  ok_enum = true
                end
              end
              if not ok_enum then
                table.insert(errors, path .. name .. "[" .. idx .. "] not in enum")
              end
            end
          end
          if prop.minItems and #value[name] < prop.minItems then
            table.insert(errors, path .. name .. " fewer than minItems")
          end
        elseif prop.type == "object" and prop.properties and type(value[name]) == "table" then
          validate_properties(value[name], prop, path .. name .. ".", errors)
        end
        if prop.format == "date-time" and actual_type == "string" then
          if not tostring(value[name]):match "^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$" then
            table.insert(errors, path .. name .. " invalid date-time")
          end
        end
        if prop.minimum and actual_type == "number" and value[name] < prop.minimum then
          table.insert(errors, path .. name .. " below minimum")
        end
        if prop.maximum and actual_type == "number" and value[name] > prop.maximum then
          table.insert(errors, path .. name .. " above maximum")
        end
      end
    end
  end
end

local function validate_against(schema, value, path, errors)
  local actual = type_of(value)
  if schema.type and actual ~= schema.type then
    table.insert(errors, path .. "expected " .. schema.type .. ", got " .. actual)
    return
  end
  if schema.type == "object" and type(value) == "table" then
    validate_properties(value, schema, path, errors)
  elseif schema.type == "array" and type(value) == "table" then
    if schema.items then
      for idx, item in ipairs(value) do
        validate_against(schema.items, item, path .. "[" .. idx .. "].", errors)
      end
    end
  end
end

function Schema.validate(schema_name, value)
  if SCHEMA_MODE ~= "embedded" then
    local ok, err = Schema.validate_python(schema_name, value)
    if ok ~= nil then
      return ok, err
    end -- nil means fallback to embedded
  end
  local schema = SCHEMAS[schema_name]
  if not schema then
    return true
  end
  local errors = {}
  validate_against(schema, value, "", errors)
  if #errors > 0 then
    return false, errors
  end
  return true
end

-- Validate against a schema table passed at runtime (same rules as embedded validator)
function Schema.validate_custom(schema_table, value)
  if not schema_table then
    return true
  end
  local errors = {}
  validate_against(schema_table, value, "", errors)
  if #errors > 0 then
    return false, errors
  end
  return true
end

-- Python/jsonschema validator (optional). Returns nil if not usable.
function Schema.validate_python(schema_name, value)
  local has_py = os.execute 'python3 -c "import jsonschema" >/dev/null 2>&1'
  if has_py ~= true and has_py ~= 0 then
    return nil, "python_jsonschema_missing"
  end
  local schema_path = "schemas/" .. schema_name .. ".schema.json"
  local f = io.open(schema_path, "r")
  if not f then
    return nil, "schema_not_found"
  end
  f:close()
  local tmp = os.tmpname() .. ".json"
  local jf = io.open(tmp, "w")
  if not jf then
    return nil, "tmp_write_failed"
  end
  local function json_encode(v)
    local t = type(v)
    if t == "nil" then
      return "null"
    end
    if t == "boolean" then
      return v and "true" or "false"
    end
    if t == "number" then
      return tostring(v)
    end
    if t == "string" then
      return string.format("%q", v)
    end
    if t == "table" then
      local is_array = true
      local i = 0
      for _, _ in pairs(v) do
        i = i + 1
        if v[i] == nil then
          is_array = false
        end
      end
      local parts = {}
      if is_array then
        for _, item in ipairs(v) do
          table.insert(parts, json_encode(item))
        end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        for k, item in pairs(v) do
          table.insert(parts, string.format("%q:%s", tostring(k), json_encode(item)))
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    end
    return '"<unsupported>"'
  end
  jf:write(json_encode(value))
  jf:close()
  local cmd = string.format(
    [[python3 - <<'PY'
import json,sys,jsonschema
with open(%q) as f: schema=json.load(f)
with open(%q) as f: inst=json.load(f)
try:
 jsonschema.validate(inst, schema)
 sys.exit(0)
except jsonschema.ValidationError:
 sys.exit(1)
PY]],
    schema_path,
    tmp
  )
  local ok = os.execute(cmd)
  os.remove(tmp)
  if ok == 0 or ok == true then
    return true
  end
  -- If validation fails, treat as schema error; otherwise fallback
  if ok == 256 or ok == false then
    return false, { "python_validator_failed" }
  end
  return nil, "python_validator_unavailable"
end

return Schema
]====], "ao.shared.schema")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.seo"] = function()
  local loaded, err = load([====[-- Minimal SEO helpers (JSON-LD generators). Not wired by default.

local cjson_ok, cjson = pcall(require, "cjson.safe")

local SEO = {}

local function encode(ld)
  if not cjson_ok then
    return nil
  end
  return cjson.encode(ld)
end

-- Products ---------------------------------------------------------------
function SEO.product_ld(product)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "Product",
    name = product.name,
    description = product.description,
    sku = product.sku,
    image = product.image,
    brand = product.brand,
    category = product.category,
    offers = {
      ["@type"] = "Offer",
      price = product.price,
      priceCurrency = product.currency,
      availability = product.available and "https://schema.org/InStock"
        or "https://schema.org/OutOfStock",
      url = product.url,
      itemCondition = product.condition,
    },
  }
end

-- Articles / blog --------------------------------------------------------
function SEO.article_ld(article)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "Article",
    headline = article.title,
    datePublished = article.publishedAt,
    dateModified = article.updatedAt or article.publishedAt,
    author = article.author and { ["@type"] = "Person", name = article.author } or nil,
    image = article.image,
    description = article.description,
    mainEntityOfPage = article.url,
  }
end

-- Breadcrumbs ------------------------------------------------------------
function SEO.breadcrumb_ld(crumbs)
  local item_list = {}
  for idx, crumb in ipairs(crumbs or {}) do
    table.insert(item_list, {
      ["@type"] = "ListItem",
      position = idx,
      name = crumb.name,
      item = crumb.url,
    })
  end
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "BreadcrumbList",
    itemListElement = item_list,
  }
end

-- FAQ --------------------------------------------------------------------
function SEO.faq_ld(items)
  local qas = {}
  for _, qa in ipairs(items or {}) do
    table.insert(qas, {
      ["@type"] = "Question",
      name = qa.question,
      acceptedAnswer = { ["@type"] = "Answer", text = qa.answer },
    })
  end
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "FAQPage",
    mainEntity = qas,
  }
end

-- Organization -----------------------------------------------------------
function SEO.organization_ld(org)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "Organization",
    name = org.name,
    url = org.url,
    logo = org.logo,
    sameAs = org.sameAs,
    contactPoint = org.contact and {
      ["@type"] = "ContactPoint",
      telephone = org.contact.phone,
      contactType = org.contact.type or "customer support",
      areaServed = org.contact.areaServed,
      availableLanguage = org.contact.languages,
    } or nil,
  }
end

-- WebPage ----------------------------------------------------------------
function SEO.page_ld(page)
  return encode {
    ["@context"] = "https://schema.org",
    ["@type"] = "WebPage",
    name = page.title or page.name,
    description = page.description,
    url = page.url,
    inLanguage = page.locale,
  }
end

-- Canonical / hreflang helpers -------------------------------------------
function SEO.canonical(base_url, path)
  if not base_url or base_url == "" then
    return path
  end
  if base_url:sub(-1) == "/" then
    base_url = base_url:sub(1, -2)
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  return base_url .. path
end

---Build hreflang link map.
-- @param base_url string e.g. https://example.com
-- @param path string normalized path without locale prefix
-- @param locales { supported = { "en", "de" }, default = "en" }
function SEO.hreflang_links(base_url, path, locales)
  if not locales or not locales.supported then
    return {}
  end
  local links = {}
  for _, loc in ipairs(locales.supported) do
    local href = SEO.canonical(base_url, "/" .. loc .. path)
    table.insert(links, { rel = "alternate", hreflang = loc:lower(), href = href })
  end
  -- x-default
  local default_href = SEO.canonical(base_url, "/" .. (locales.default or "en") .. path)
  table.insert(links, { rel = "alternate", hreflang = "x-default", href = default_href })
  return links
end

-- Sitemaps / robots.txt --------------------------------------------------
function SEO.sitemap(urls)
  local buffer = {
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">',
  }
  for _, u in ipairs(urls or {}) do
    table.insert(buffer, "<url>")
    table.insert(buffer, string.format("<loc>%s</loc>", u.loc))
    if u.lastmod then
      table.insert(buffer, string.format("<lastmod>%s</lastmod>", u.lastmod))
    end
    if u.changefreq then
      table.insert(buffer, string.format("<changefreq>%s</changefreq>", u.changefreq))
    end
    if u.priority then
      table.insert(buffer, string.format("<priority>%.1f</priority>", u.priority))
    end
    table.insert(buffer, "</url>")
  end
  table.insert(buffer, "</urlset>")
  return table.concat(buffer, "\n")
end

function SEO.robots_txt(opts)
  opts = opts or {}
  local lines = {
    "User-agent: *",
    string.format("Disallow: %s", opts.disallow or ""),
  }
  if opts.allow then
    table.insert(lines, string.format("Allow: %s", opts.allow))
  end
  if opts.sitemap then
    table.insert(lines, "Sitemap: " .. opts.sitemap)
  end
  return table.concat(lines, "\n")
end

return SEO
]====], "ao.shared.seo")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.timer"] = function()
  local loaded, err = load([====[-- Minimal timer abstraction using luv if available.
-- Returns no-op functions when luv is absent.

local ok, uv = pcall(require, "luv")

local Timer = {}
local started = false

function Timer.start(interval_sec, fn)
  if not ok or not uv or started then
    return
  end
  if not interval_sec or interval_sec <= 0 then
    return
  end
  local t = uv.new_timer()
  if not t then
    return
  end
  started = true
  t:start(interval_sec * 1000, interval_sec * 1000, function()
    pcall(fn)
  end)
end

function Timer.is_started()
  return started
end

return Timer
]====], "ao.shared.timer")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.shared.validation"] = function()
  local loaded, err = load([====[-- Shared schema validation and payload guards (lightweight).
-- This keeps minimal synchronous guards in-process; deeper JSON schema checks
-- should be handled by the upstream bridge or a dedicated validator.

local Validation = {}

Validation.required_tags = {
  "Action",
  "Request-Id",
}

local function contains(list, value)
  for _, v in ipairs(list) do
    if v == value then
      return true
    end
  end
  return false
end

function Validation.require_tags(msg, extra)
  local missing = {}
  for _, key in ipairs(Validation.required_tags) do
    if msg[key] == nil then
      table.insert(missing, key)
    end
  end
  if extra then
    for _, key in ipairs(extra) do
      if msg[key] == nil then
        table.insert(missing, key)
      end
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true
end

function Validation.require_action(msg, allowed)
  local action = msg.Action
  if not action then
    return false, "missing_action"
  end
  if allowed and not contains(allowed, action) then
    return false, "unknown_action"
  end
  return true
end

-- Convenience check for allowlist
function Validation.is_allowed_action(action, allowed)
  if not action then
    return false
  end
  if not allowed then
    return true
  end
  return contains(allowed, action)
end

-- Validate presence of required fields in a table payload.
function Validation.require_fields(tbl, fields)
  local missing = {}
  for _, f in ipairs(fields) do
    if tbl[f] == nil then
      table.insert(missing, f)
    end
  end
  if #missing > 0 then
    return false, missing
  end
  return true
end

-- Validate that no unexpected fields are present (shallow).
function Validation.require_no_extras(tbl, allowed_fields)
  if not allowed_fields then
    return true
  end
  local allowed = {
    -- Cross-cutting auth/telemetry fields that every handler should tolerate.
    Nonce = true,
    nonce = true,
    ts = true,
    timestamp = true,
    ["Timestamp"] = true,
    Signature = true,
    signature = true,
    ["Signature-Ref"] = true,
    Authorization = true,
    authorization = true,
    auth = true,
    JWT = true,
    jwt = true,
    -- AO envelope fields that can be present on incoming messages.
    From = true,
    from = true,
    Id = true,
    id = true,
    Owner = true,
    owner = true,
    Target = true,
    target = true,
    Anchor = true,
    anchor = true,
    Data = true,
    data = true,
    Body = true,
    body = true,
    Tags = true,
    tags = true,
  }
  for _, f in ipairs(allowed_fields) do
    allowed[f] = true
  end
  local extras = {}
  for k, _ in pairs(tbl) do
    if not allowed[k] then
      table.insert(extras, k)
    end
  end
  if #extras > 0 then
    return false, extras
  end
  return true
end

-- Optional payload size guard (bytes when serialized length provided).
function Validation.check_size(len, max_bytes, field)
  if not max_bytes or max_bytes <= 0 or not len then
    return true
  end
  if len > max_bytes then
    return false, ("too_large:%s"):format(field or "?")
  end
  return true
end

function Validation.assert_type(value, expected, field)
  if type(value) ~= expected then
    return false, ("invalid_type:%s"):format(field or "?")
  end
  return true
end

-- Check maximum string length.
function Validation.check_length(value, max_len, field)
  if not value or not max_len or max_len <= 0 then
    return true
  end
  if #tostring(value) > max_len then
    return false, ("too_long:%s"):format(field or "?")
  end
  return true
end

local function is_array(tbl)
  local i = 0
  for _ in pairs(tbl) do
    i = i + 1
    if tbl[i] == nil then
      return false
    end
  end
  return true
end

local function json_encoded_length(value)
  local t = type(value)
  if t == "nil" then
    return 4
  end -- null
  if t == "boolean" then
    return value and 4 or 5
  end -- true/false
  if t == "number" then
    return #tostring(value)
  end
  if t == "string" then
    return #string.format("%q", value)
  end
  if t == "table" then
    if is_array(value) then
      local sum = 2 -- []
      local first = true
      for _, v in ipairs(value) do
        if not first then
          sum = sum + 1
        end -- comma
        sum = sum + json_encoded_length(v)
        first = false
      end
      return sum
    else
      local sum = 2 -- {}
      local first = true
      for k, v in pairs(value) do
        if not first then
          sum = sum + 1
        end -- comma
        sum = sum + #string.format("%q", tostring(k)) + 1 + json_encoded_length(v) -- colon
        first = false
      end
      return sum
    end
  end
  return #tostring(value)
end

-- Rough estimate of JSON-encoded length (bytes) for payload size guards.
function Validation.estimate_json_length(value)
  return json_encoded_length(value)
end

-- Envelope/command validation used by both write and AO processes.
-- Normalizes common field names so downstream code can rely on canonical keys.
function Validation.validate_envelope(cmd)
  if not cmd then
    return false, { "missing_envelope" }
  end
  cmd.action = cmd.action or cmd.Action
  cmd.requestId = cmd.requestId or cmd["Request-Id"]
  cmd.payload = cmd.payload or cmd.Payload or {}
  cmd.actor = cmd.actor or cmd.Actor
  cmd.actorRole = cmd.actorRole or cmd["Actor-Role"] or cmd.role
  cmd.tenant = cmd.tenant or cmd.Tenant or cmd["Tenant-Id"]
  cmd.siteId = cmd.siteId or cmd["Site-Id"] or cmd.SiteId
  cmd.gatewayId = cmd.gatewayId or cmd["Gateway-Id"] or cmd.gateway

  local ok_tags, missing = Validation.require_tags {
    Action = cmd.action,
    ["Request-Id"] = cmd.requestId,
  }
  if not ok_tags then
    return false, missing
  end
  return true
end

-- Per-action payload validation stub (can be extended with schemas).
function Validation.validate_action(_action, _payload)
  return true
end

-- Optional payload size guard; falls back to estimate when length not provided.
function Validation.check_payload_size(payload, max_bytes)
  if not max_bytes or max_bytes <= 0 then
    return true
  end
  local est = Validation.estimate_json_length(payload)
  if est > max_bytes then
    return false, ("too_large:%s"):format(max_bytes)
  end
  return true
end

-- Nonce/timestamp helpers (no-ops by default; override in stricter builds).
function Validation.require_nonce_fields(_msg)
  return true
end

function Validation.require_timestamp(_msg)
  return true
end

return Validation
]====], "ao.shared.validation")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


package.preload["ao.resolver.process"] = function()
  local loaded, err = load([====[-- Resolver process scaffold: host -> decision contract for HB policy routing.
-- This v1 intentionally fails open and defaults to mode=off.

local codec = require "ao.shared.codec"
local validation = require "ao.shared.validation"
local auth = require "ao.shared.auth"
local idem = require "ao.shared.idempotency"
local metrics = require "ao.shared.metrics"
local persist = require "ao.shared.persist"

local handlers = {}
local map_count
local allowed_actions = {
  "ResolveHostForNode",
  "ResolveRouteForHost",
  "GetResolverState",
  "ApplyPolicyBundle",
  "ApplyHostPolicyFromProof",
  "InvalidateResolverCache",
  "GetResolverCacheStats",
  "GetDnsRefreshState",
  "ListHostsDueForDnsRefresh",
  "RunAutoDnsTick",
  "ApplyDnsRefreshResult",
  "ForceDnsRefreshHost",
  "IssueDnsRefreshChallenge",
  "SetAdmissionRule",
  "RemoveAdmissionRule",
  "GetAdmissionState",
}

local public_read_actions = {
  ResolveHostForNode = true,
  ResolveRouteForHost = true,
  GetResolverState = true, -- safe summary only
  GetResolverCacheStats = true, -- safe summary only
  GetDnsRefreshState = true, -- safe summary only
}

local role_policy = {
  ApplyPolicyBundle = { "admin", "registry-admin" },
  InvalidateResolverCache = { "admin", "registry-admin" },
  ListHostsDueForDnsRefresh = { "admin", "registry-admin" },
  RunAutoDnsTick = { "admin", "registry-admin" },
  ApplyDnsRefreshResult = { "admin", "registry-admin", "resolver-refresh" },
  ForceDnsRefreshHost = { "admin", "registry-admin", "resolver-refresh" },
  IssueDnsRefreshChallenge = { "admin", "registry-admin", "resolver-refresh" },
  ApplyHostPolicyFromProof = { "admin", "registry-admin", "resolver-refresh" },
  SetAdmissionRule = { "admin", "registry-admin" },
  RemoveAdmissionRule = { "admin", "registry-admin" },
}

local hmac_skip_actions = {
  ResolveHostForNode = true,
  ResolveRouteForHost = true,
  GetResolverState = true,
  GetResolverCacheStats = true,
  GetDnsRefreshState = true,
}

local VALID_POLICY_MODES = {
  off = true,
  observe = true,
  soft = true,
  enforce = true,
}

local PUBLIC_READ_REQUIRE_AUTH = (os.getenv "RESOLVER_PUBLIC_READ_REQUIRE_AUTH" or "0") == "1"
local MAX_HOST_BYTES = tonumber(os.getenv "RESOLVER_MAX_HOST_BYTES" or "") or 253
local MAX_PATH_BYTES = tonumber(os.getenv "RESOLVER_MAX_PATH_BYTES" or "") or 2048
local MAX_METHOD_BYTES = tonumber(os.getenv "RESOLVER_MAX_METHOD_BYTES" or "") or 16
local RESOLUTION_CACHE_MAX_ENTRIES = tonumber(os.getenv "RESOLVER_CACHE_MAX_ENTRIES" or "") or 20000
local REFRESH_META_MAX_HOSTS = tonumber(os.getenv "RESOLVER_REFRESH_META_MAX_HOSTS" or "") or 10000
local REFRESH_META_STALE_TTL_SEC = tonumber(os.getenv "RESOLVER_REFRESH_META_STALE_TTL_SEC" or "") or 86400
local RESOLVER_PERSIST_MIN_INTERVAL_SEC = tonumber(os.getenv "RESOLVER_PERSIST_MIN_INTERVAL_SEC" or "") or 5
local ALLOW_CENTRALIZED_BUNDLE_WRITES = (os.getenv "RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES" or "0") == "1"
local ALLOW_DIRECT_HOST_POLICY_APPLY = (os.getenv "RESOLVER_ALLOW_DIRECT_HOST_POLICY_APPLY" or "0") == "1"
local ALLOW_PUBLIC_READ_REFRESH_QUEUE = (os.getenv "RESOLVER_ALLOW_PUBLIC_READ_REFRESH_QUEUE" or "0") == "1"

local mutating_actions = {
  ApplyPolicyBundle = true,
  ApplyHostPolicyFromProof = true,
  InvalidateResolverCache = true,
  RunAutoDnsTick = true,
  ApplyDnsRefreshResult = true,
  ForceDnsRefreshHost = true,
  IssueDnsRefreshChallenge = true,
  SetAdmissionRule = true,
  RemoveAdmissionRule = true,
}
local last_persist_epoch = 0
local refresh_state_mutated = false
local request_allows_refresh_queue_mutation = false
local openssl_ok, openssl = pcall(require, "openssl")
local handler_strip_fields = {
  Nonce = true,
  nonce = true,
  ts = true,
  timestamp = true,
  Timestamp = true,
  ["X-Timestamp"] = true,
  Signature = true,
  signature = true,
  ["Signature-Ref"] = true,
  Authorization = true,
  authorization = true,
  auth = true,
  jwt = true,
  JWT = true,
  token = true,
  ["Device-Token"] = true,
  deviceToken = true,
  device_token = true,
  device = true,
  ["Actor-Id"] = true,
  Subject = true,
  Tenant = true,
  ["Tenant-Id"] = true,
  jwt_claims = true,
}

local state = persist.load("resolver_state", {
  policyMode = "off", -- off|observe|soft|enforce
  failOpen = true,
  cacheHints = {
    positiveTtlSec = 300,
    negativeTtlSec = 60,
    staleWhileRevalidateSec = 900,
    hardMaxStaleSec = 3600,
  },
  hostPolicies = {}, -- host -> { siteId, processId, moduleId, scheduler, routePrefix, status }
  sitePolicies = {}, -- siteId -> { processId, moduleId, scheduler, routePrefix, status }
  routePolicies = {}, -- host -> { defaultActionHint?, rules = { { pathPrefix, methods?, actionHint } } }
  dnsProofState = {}, -- host -> { state, checkedAt, validUntil, source, challengeRef, sequence }
  refreshMeta = {}, -- host -> { nextCheckAt, lastCheckAt, lastError, retryCount, pendingChallenge, challengeExpiresAt }
  autoDns = {
    enabled = false,
    refreshIntervalSec = 300,
    maxHostsPerRun = 100,
    staleGraceSec = 900,
    refreshOnStale = true,
    staleRefreshMinIntervalSec = 30,
    relayPath = "/~relay@1.0",
    cachePath = "/~cache@1.0",
    cronPath = "/~cron@1.0",
    dohEndpoint = "https://cloudflare-dns.com/dns-query",
    arweaveBase = "https://arweave.net",
    requireChallenge = false,
    challengeTtlSec = 300,
  },
  executionFlow = {
    mode = "slot_pinned_preflight",
    preflightSchedule = true,
    requireNumericSlot = true,
    singleFlightPerProcess = true,
    maxAttempts = 5,
    baseBackoffMs = 300,
    maxBackoffMs = 1000,
  },
  admission = {
    allowlistEnabled = false,
    allowHosts = {}, -- exact host -> { reason?, updatedAt? }
    denyHosts = {}, -- exact host -> { reason?, updatedAt? }
    updatedAt = nil,
  },
  resolutionCache = {}, -- host -> { host, siteId?, decision, reasonCode, mode, proofState, cachedAt, expiresAt, surface }
  bundleMeta = { -- latest applied bundle metadata
    snapshotId = nil,
    version = nil,
    generatedAt = nil,
    appliedAt = nil,
  },
  cacheMeta = {
    lastInvalidatedAt = nil,
  },
  lastResolvedAt = nil,
})

local function now_iso()
  return os.date "!%Y-%m-%dT%H:%M:%SZ"
end

local function plus_seconds_iso(seconds)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + math.max(0, tonumber(seconds) or 0))
end

local function sanitize_handler_message(msg)
  local out = {}
  for key, value in pairs(msg or {}) do
    if not handler_strip_fields[key] then
      out[key] = value
    end
  end
  return out
end

local function trim(text)
  if type(text) ~= "string" then
    return text
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_node_id(msg)
  local node_id = msg["Node-Id"] or msg.nodeId or msg["Resolver-Id"]
  if node_id == nil then
    return nil
  end
  local ok_len, err_len = validation.check_length(node_id, 128, "Node-Id")
  if not ok_len then
    return nil, err_len
  end
  return tostring(node_id)
end

local function read_request_id(msg)
  local request_id = msg["Request-Id"] or msg.requestId
  if type(request_id) ~= "string" then
    return ""
  end
  return trim(request_id) or ""
end

local function normalize_host(raw_host, field_name)
  local field = field_name or "Host"
  if type(raw_host) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end

  local host = trim(raw_host)
  if host == nil or host == "" then
    return nil, ("invalid_format:%s"):format(field)
  end

  -- Host header can contain a single ":<port>" suffix; strip it.
  local name, port = host:match("^([^:]+):(%d+)$")
  if name and port then
    host = name
  end

  host = string.lower(host)
  host = host:gsub("%.$", "")

  local ok_len, err_len = validation.check_length(host, MAX_HOST_BYTES, field)
  if not ok_len then
    return nil, err_len
  end

  if host == "" or host:find("%.%.", 1, true) then
    return nil, ("invalid_format:%s"):format(field)
  end
  if host:find("[/%?#@%[%] ]") then
    return nil, ("invalid_format:%s"):format(field)
  end
  if not host:match "^[a-z0-9%.%-]+$" then
    return nil, ("invalid_format:%s"):format(field)
  end

  for label in host:gmatch("[^.]+") do
    if #label == 0 or #label > 63 then
      return nil, ("invalid_format:%s"):format(field)
    end
    if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
      return nil, ("invalid_format:%s"):format(field)
    end
  end

  return host
end

local function normalize_process_identifier(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  local value = trim(tostring(raw_value)) or ""
  if value == "" then
    return nil
  end
  local ok_len, err_len = validation.check_length(value, 128, field_name)
  if not ok_len then
    return nil, err_len
  end
  if #value < 20 or not value:match "^[A-Za-z0-9_-]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  return value
end

local normalize_path

local function ensure_cache_hints()
  state.cacheHints = state.cacheHints or {}
  state.cacheHints.positiveTtlSec = tonumber(state.cacheHints.positiveTtlSec) or 300
  state.cacheHints.negativeTtlSec = tonumber(state.cacheHints.negativeTtlSec) or 60
  state.cacheHints.staleWhileRevalidateSec = tonumber(state.cacheHints.staleWhileRevalidateSec) or 900
  state.cacheHints.hardMaxStaleSec = tonumber(state.cacheHints.hardMaxStaleSec) or 3600
end

local function ensure_state_defaults()
  local mode = tostring(state.policyMode or "off"):lower()
  if not VALID_POLICY_MODES[mode] then
    mode = "off"
  end
  state.policyMode = mode
  state.failOpen = state.failOpen ~= false
  if type(state.hostPolicies) ~= "table" then
    state.hostPolicies = {}
  end
  if type(state.sitePolicies) ~= "table" then
    state.sitePolicies = {}
  end
  if type(state.routePolicies) ~= "table" then
    state.routePolicies = {}
  end
  if type(state.dnsProofState) ~= "table" then
    state.dnsProofState = {}
  end
  if type(state.refreshMeta) ~= "table" then
    state.refreshMeta = {}
  end
  if type(state.autoDns) ~= "table" then
    state.autoDns = {}
  end
  state.autoDns.enabled = state.autoDns.enabled == true
  state.autoDns.refreshIntervalSec = tonumber(state.autoDns.refreshIntervalSec) or 300
  if state.autoDns.refreshIntervalSec < 30 then
    state.autoDns.refreshIntervalSec = 30
  end
  if state.autoDns.refreshIntervalSec > 86400 then
    state.autoDns.refreshIntervalSec = 86400
  end
  state.autoDns.maxHostsPerRun = tonumber(state.autoDns.maxHostsPerRun) or 100
  if state.autoDns.maxHostsPerRun < 1 then
    state.autoDns.maxHostsPerRun = 1
  end
  if state.autoDns.maxHostsPerRun > 500 then
    state.autoDns.maxHostsPerRun = 500
  end
  state.autoDns.staleGraceSec = tonumber(state.autoDns.staleGraceSec) or 900
  if state.autoDns.staleGraceSec < 0 then
    state.autoDns.staleGraceSec = 0
  end
  if state.autoDns.staleGraceSec > 172800 then
    state.autoDns.staleGraceSec = 172800
  end
  state.autoDns.refreshOnStale = state.autoDns.refreshOnStale ~= false
  state.autoDns.staleRefreshMinIntervalSec = tonumber(state.autoDns.staleRefreshMinIntervalSec) or 30
  if state.autoDns.staleRefreshMinIntervalSec < 0 then
    state.autoDns.staleRefreshMinIntervalSec = 0
  end
  if state.autoDns.staleRefreshMinIntervalSec > 86400 then
    state.autoDns.staleRefreshMinIntervalSec = 86400
  end
  state.autoDns.requireChallenge = state.autoDns.requireChallenge == true
  state.autoDns.challengeTtlSec = tonumber(state.autoDns.challengeTtlSec) or 300
  if state.autoDns.challengeTtlSec < 30 then
    state.autoDns.challengeTtlSec = 30
  end
  if state.autoDns.challengeTtlSec > 7200 then
    state.autoDns.challengeTtlSec = 7200
  end
  state.autoDns.relayPath = state.autoDns.relayPath or "/~relay@1.0"
  state.autoDns.cachePath = state.autoDns.cachePath or "/~cache@1.0"
  state.autoDns.cronPath = state.autoDns.cronPath or "/~cron@1.0"
  state.autoDns.dohEndpoint = state.autoDns.dohEndpoint or "https://cloudflare-dns.com/dns-query"
  state.autoDns.arweaveBase = state.autoDns.arweaveBase or "https://arweave.net"
  if type(state.executionFlow) ~= "table" then
    state.executionFlow = {}
  end
  local flow_mode = tostring(state.executionFlow.mode or "slot_pinned_preflight"):lower()
  if flow_mode ~= "slot_pinned_preflight" then
    flow_mode = "slot_pinned_preflight"
  end
  state.executionFlow.mode = flow_mode
  state.executionFlow.preflightSchedule = state.executionFlow.preflightSchedule ~= false
  state.executionFlow.requireNumericSlot = state.executionFlow.requireNumericSlot ~= false
  state.executionFlow.singleFlightPerProcess = state.executionFlow.singleFlightPerProcess ~= false
  state.executionFlow.maxAttempts = tonumber(state.executionFlow.maxAttempts) or 5
  if state.executionFlow.maxAttempts < 1 then
    state.executionFlow.maxAttempts = 1
  end
  if state.executionFlow.maxAttempts > 10 then
    state.executionFlow.maxAttempts = 10
  end
  state.executionFlow.baseBackoffMs = tonumber(state.executionFlow.baseBackoffMs) or 300
  if state.executionFlow.baseBackoffMs < 50 then
    state.executionFlow.baseBackoffMs = 50
  end
  if state.executionFlow.baseBackoffMs > 5000 then
    state.executionFlow.baseBackoffMs = 5000
  end
  state.executionFlow.maxBackoffMs = tonumber(state.executionFlow.maxBackoffMs) or 1000
  if state.executionFlow.maxBackoffMs < state.executionFlow.baseBackoffMs then
    state.executionFlow.maxBackoffMs = state.executionFlow.baseBackoffMs
  end
  if state.executionFlow.maxBackoffMs > 10000 then
    state.executionFlow.maxBackoffMs = 10000
  end
  if type(state.admission) ~= "table" then
    state.admission = {}
  end
  state.admission.allowlistEnabled = state.admission.allowlistEnabled == true
  if type(state.admission.allowHosts) ~= "table" then
    state.admission.allowHosts = {}
  end
  if type(state.admission.denyHosts) ~= "table" then
    state.admission.denyHosts = {}
  end
  for host, entry in pairs(state.admission.allowHosts) do
    local normalized_host = normalize_host(host, "admission.allowHosts")
    if not normalized_host then
      state.admission.allowHosts[host] = nil
    else
      if normalized_host ~= host then
        state.admission.allowHosts[host] = nil
      end
      if type(entry) ~= "table" then
        entry = {}
      end
      state.admission.allowHosts[normalized_host] = {
        reason = entry.reason,
        updatedAt = entry.updatedAt,
      }
    end
  end
  for host, entry in pairs(state.admission.denyHosts) do
    local normalized_host = normalize_host(host, "admission.denyHosts")
    if not normalized_host then
      state.admission.denyHosts[host] = nil
    else
      if normalized_host ~= host then
        state.admission.denyHosts[host] = nil
      end
      if type(entry) ~= "table" then
        entry = {}
      end
      state.admission.denyHosts[normalized_host] = {
        reason = entry.reason,
        updatedAt = entry.updatedAt,
      }
    end
  end
  if type(state.resolutionCache) ~= "table" then
    state.resolutionCache = {}
  end
  if type(state.bundleMeta) ~= "table" then
    state.bundleMeta = { appliedAt = nil }
  end
  if type(state.cacheMeta) ~= "table" then
    state.cacheMeta = { lastInvalidatedAt = nil }
  end
  ensure_cache_hints()
end

ensure_state_defaults()

local function normalize_mode(mode)
  local normalized = tostring(mode or state.policyMode or "off"):lower()
  if VALID_POLICY_MODES[normalized] then
    return normalized, nil
  end
  return "off", "ERROR_INVALID_POLICY_MODE_FALLBACK"
end

local function parse_fail_open(value, current_value)
  if value == nil then
    return current_value
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    if value == 1 then
      return true
    end
    if value == 0 then
      return false
    end
  end
  if type(value) == "string" then
    local lower = string.lower(value)
    if lower == "1" or lower == "true" or lower == "yes" then
      return true
    end
    if lower == "0" or lower == "false" or lower == "no" then
      return false
    end
  end
  return nil, "invalid_boolean:Fail-Open"
end

local function parse_boolean_field(value, field_name, current_value)
  local parsed, parse_err = parse_fail_open(value, current_value)
  if parsed == nil then
    return nil, parse_err or ("invalid_boolean:%s"):format(field_name)
  end
  return parsed, nil
end

local function normalize_device_path(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  if type(raw_value) ~= "string" then
    return nil, ("invalid_type:%s"):format(field_name)
  end
  local normalized, path_err = normalize_path(raw_value, field_name)
  if not normalized then
    return nil, path_err
  end
  if not normalized:match "^/~[a-z0-9%-]+@[%d%.]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  return normalized
end

local function normalize_https_url(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  if type(raw_value) ~= "string" then
    return nil, ("invalid_type:%s"):format(field_name)
  end
  local value = trim(raw_value) or ""
  if value == "" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  if not value:match "^https://[%w%-%._~:/%?#%[%]@!$&'()%*+,;=]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  local ok_len, err_len = validation.check_length(value, 512, field_name)
  if not ok_len then
    return nil, err_len
  end
  return value
end

local function normalize_auto_dns(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:autoDns"
  end

  local out = {}
  local function parse_int(raw_value, field_name, min_value, max_value)
    local value = tonumber(raw_value)
    if not value or value % 1 ~= 0 then
      return nil, ("invalid_number:%s"):format(field_name)
    end
    if value < min_value or value > max_value then
      return nil, ("invalid_range:%s"):format(field_name)
    end
    return value, nil
  end
  if input.enabled ~= nil then
    local enabled, enabled_err = parse_boolean_field(input.enabled, "autoDns.enabled", state.autoDns.enabled == true)
    if enabled_err then
      return nil, enabled_err
    end
    out.enabled = enabled
  end
  if input.refreshOnStale ~= nil then
    local refresh_on_stale, refresh_on_stale_err =
      parse_boolean_field(input.refreshOnStale, "autoDns.refreshOnStale", state.autoDns.refreshOnStale ~= false)
    if refresh_on_stale_err then
      return nil, refresh_on_stale_err
    end
    out.refreshOnStale = refresh_on_stale
  end
  if input.requireChallenge ~= nil then
    local require_challenge, require_challenge_err = parse_boolean_field(
      input.requireChallenge,
      "autoDns.requireChallenge",
      state.autoDns.requireChallenge == true
    )
    if require_challenge_err then
      return nil, require_challenge_err
    end
    out.requireChallenge = require_challenge
  end
  if input.refreshIntervalSec ~= nil then
    local parsed, parsed_err = parse_int(input.refreshIntervalSec, "autoDns.refreshIntervalSec", 30, 86400)
    if parsed_err then
      return nil, parsed_err
    end
    out.refreshIntervalSec = parsed
  end
  if input.maxHostsPerRun ~= nil then
    local parsed, parsed_err = parse_int(input.maxHostsPerRun, "autoDns.maxHostsPerRun", 1, 500)
    if parsed_err then
      return nil, parsed_err
    end
    out.maxHostsPerRun = parsed
  end
  if input.staleGraceSec ~= nil then
    local parsed, parsed_err = parse_int(input.staleGraceSec, "autoDns.staleGraceSec", 0, 172800)
    if parsed_err then
      return nil, parsed_err
    end
    out.staleGraceSec = parsed
  end
  if input.staleRefreshMinIntervalSec ~= nil then
    local parsed, parsed_err = parse_int(
      input.staleRefreshMinIntervalSec,
      "autoDns.staleRefreshMinIntervalSec",
      0,
      86400
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.staleRefreshMinIntervalSec = parsed
  end
  if input.challengeTtlSec ~= nil then
    local parsed, parsed_err = parse_int(input.challengeTtlSec, "autoDns.challengeTtlSec", 30, 7200)
    if parsed_err then
      return nil, parsed_err
    end
    out.challengeTtlSec = parsed
  end
  if input.relayPath ~= nil then
    local relay_path, relay_path_err = normalize_device_path(input.relayPath, "autoDns.relayPath")
    if relay_path_err then
      return nil, relay_path_err
    end
    out.relayPath = relay_path
  end
  if input.cachePath ~= nil then
    local cache_path, cache_path_err = normalize_device_path(input.cachePath, "autoDns.cachePath")
    if cache_path_err then
      return nil, cache_path_err
    end
    out.cachePath = cache_path
  end
  if input.cronPath ~= nil then
    local cron_path, cron_path_err = normalize_device_path(input.cronPath, "autoDns.cronPath")
    if cron_path_err then
      return nil, cron_path_err
    end
    out.cronPath = cron_path
  end
  if input.dohEndpoint ~= nil then
    local doh_endpoint, doh_endpoint_err = normalize_https_url(input.dohEndpoint, "autoDns.dohEndpoint")
    if doh_endpoint_err then
      return nil, doh_endpoint_err
    end
    out.dohEndpoint = doh_endpoint
  end
  if input.arweaveBase ~= nil then
    local arweave_base, arweave_base_err = normalize_https_url(input.arweaveBase, "autoDns.arweaveBase")
    if arweave_base_err then
      return nil, arweave_base_err
    end
    out.arweaveBase = arweave_base
  end
  return out
end

local function normalize_cache_hints(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:Cache-Hints"
  end
  local function parse_cache_hint_number(raw_value, hint_name, min_value, max_value)
    local value = tonumber(raw_value)
    if not value or value % 1 ~= 0 then
      return nil, ("invalid_number:%s"):format(hint_name)
    end
    if value < min_value or value > max_value then
      return nil, ("invalid_range:%s"):format(hint_name)
    end
    return value, nil
  end
  local out = {}
  if input.positiveTtlSec ~= nil then
    local parsed, parse_err = parse_cache_hint_number(input.positiveTtlSec, "positiveTtlSec", 1, 86400)
    if parse_err then
      return nil, parse_err
    end
    out.positiveTtlSec = parsed
  end
  if input.negativeTtlSec ~= nil then
    local parsed, parse_err = parse_cache_hint_number(input.negativeTtlSec, "negativeTtlSec", 1, 86400)
    if parse_err then
      return nil, parse_err
    end
    out.negativeTtlSec = parsed
  end
  if input.staleWhileRevalidateSec ~= nil then
    local parsed, parse_err =
      parse_cache_hint_number(input.staleWhileRevalidateSec, "staleWhileRevalidateSec", 0, 86400)
    if parse_err then
      return nil, parse_err
    end
    out.staleWhileRevalidateSec = parsed
  end
  if input.hardMaxStaleSec ~= nil then
    local parsed, parse_err = parse_cache_hint_number(input.hardMaxStaleSec, "hardMaxStaleSec", 0, 172800)
    if parse_err then
      return nil, parse_err
    end
    out.hardMaxStaleSec = parsed
  end
  return out
end

local function normalize_execution_flow(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:Execution-Flow"
  end
  local out = {}

  local function parse_int(raw_value, field_name, min_value, max_value)
    local value = tonumber(raw_value)
    if not value or value % 1 ~= 0 then
      return nil, ("invalid_number:%s"):format(field_name)
    end
    if value < min_value or value > max_value then
      return nil, ("invalid_range:%s"):format(field_name)
    end
    return value, nil
  end

  if input.mode ~= nil then
    local mode = tostring(input.mode):lower()
    if mode ~= "slot_pinned_preflight" then
      return nil, "invalid_format:Execution-Flow.mode"
    end
    out.mode = mode
  end
  if input.preflightSchedule ~= nil then
    local parsed, parsed_err = parse_boolean_field(
      input.preflightSchedule,
      "Execution-Flow.preflightSchedule",
      state.executionFlow.preflightSchedule ~= false
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.preflightSchedule = parsed
  end
  if input.requireNumericSlot ~= nil then
    local parsed, parsed_err = parse_boolean_field(
      input.requireNumericSlot,
      "Execution-Flow.requireNumericSlot",
      state.executionFlow.requireNumericSlot ~= false
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.requireNumericSlot = parsed
  end
  if input.singleFlightPerProcess ~= nil then
    local parsed, parsed_err = parse_boolean_field(
      input.singleFlightPerProcess,
      "Execution-Flow.singleFlightPerProcess",
      state.executionFlow.singleFlightPerProcess ~= false
    )
    if parsed_err then
      return nil, parsed_err
    end
    out.singleFlightPerProcess = parsed
  end
  if input.maxAttempts ~= nil then
    local parsed, parsed_err = parse_int(input.maxAttempts, "Execution-Flow.maxAttempts", 1, 10)
    if parsed_err then
      return nil, parsed_err
    end
    out.maxAttempts = parsed
  end
  if input.baseBackoffMs ~= nil then
    local parsed, parsed_err = parse_int(input.baseBackoffMs, "Execution-Flow.baseBackoffMs", 50, 5000)
    if parsed_err then
      return nil, parsed_err
    end
    out.baseBackoffMs = parsed
  end
  if input.maxBackoffMs ~= nil then
    local parsed, parsed_err = parse_int(input.maxBackoffMs, "Execution-Flow.maxBackoffMs", 50, 10000)
    if parsed_err then
      return nil, parsed_err
    end
    out.maxBackoffMs = parsed
  end
  if out.baseBackoffMs ~= nil and out.maxBackoffMs ~= nil and out.maxBackoffMs < out.baseBackoffMs then
    return nil, "invalid_relation:Execution-Flow.maxBackoffMs"
  end
  return out
end

local function normalize_host_policies(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:hostPolicies"
  end
  local out = {}
  for host_key, spec in pairs(input) do
    if type(spec) == "table" then
      local host, host_err = normalize_host(host_key, "hostPolicies")
      if not host then
        return nil, host_err
      end
      local site_id = spec.siteId or spec["Site-Id"] or spec.site_id
      if site_id == nil then
        return nil, ("missing_field:hostPolicies.siteId:%s"):format(host)
      end
      site_id = trim(tostring(site_id)) or ""
      local ok_site_len, site_len_err = validation.check_length(site_id, 128, "Site-Id")
      if not ok_site_len or site_id == "" then
        return nil, site_len_err or ("invalid_format:Site-Id:%s"):format(host)
      end

      local process_id, process_err =
        normalize_process_identifier(spec.processId or spec["Process-Id"] or spec.process_id, "Process-Id")
      if process_err then
        return nil, process_err
      end
      local module_id, module_err =
        normalize_process_identifier(spec.moduleId or spec["Module-Id"] or spec.module_id, "Module-Id")
      if module_err then
        return nil, module_err
      end
      local scheduler_id, scheduler_err =
        normalize_process_identifier(spec.scheduler or spec["Scheduler-Id"] or spec.scheduler_id, "Scheduler-Id")
      if scheduler_err then
        return nil, scheduler_err
      end

      local route_prefix = spec.routePrefix or spec["Route-Prefix"] or spec.route_prefix
      if route_prefix ~= nil then
        local normalized_route_prefix, route_prefix_err = normalize_path(tostring(route_prefix), "Route-Prefix")
        if not normalized_route_prefix then
          return nil, route_prefix_err
        end
        route_prefix = normalized_route_prefix
      end

      local status = spec.status
      if status ~= nil then
        status = trim(tostring(status)) or ""
        local ok_status_len, status_len_err = validation.check_length(status, 64, "status")
        if not ok_status_len or status == "" then
          return nil, status_len_err or ("invalid_format:status:%s"):format(host)
        end
      end
      local entry = {
        siteId = site_id,
        processId = process_id,
        moduleId = module_id,
        scheduler = scheduler_id,
        routePrefix = route_prefix,
        status = status,
      }
      out[host] = entry
    end
  end
  return out
end

local function normalize_site_policies(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:sitePolicies"
  end
  local out = {}
  for site_key, spec in pairs(input) do
    if type(spec) == "table" then
      local site_id = tostring(spec.siteId or spec["Site-Id"] or spec.site_id or site_key)
      local ok_len, err_len = validation.check_length(site_id, 128, "Site-Id")
      if not ok_len or site_id == "" then
        return nil, err_len or "invalid_format:Site-Id"
      end
      local process_id, process_err =
        normalize_process_identifier(spec.processId or spec["Process-Id"] or spec.process_id, "Process-Id")
      if process_err then
        return nil, process_err
      end
      local module_id, module_err =
        normalize_process_identifier(spec.moduleId or spec["Module-Id"] or spec.module_id, "Module-Id")
      if module_err then
        return nil, module_err
      end
      local scheduler_id, scheduler_err =
        normalize_process_identifier(spec.scheduler or spec["Scheduler-Id"] or spec.scheduler_id, "Scheduler-Id")
      if scheduler_err then
        return nil, scheduler_err
      end
      local route_prefix = spec.routePrefix or spec["Route-Prefix"] or spec.route_prefix
      if route_prefix ~= nil then
        local normalized_route_prefix, route_prefix_err = normalize_path(tostring(route_prefix), "Route-Prefix")
        if not normalized_route_prefix then
          return nil, route_prefix_err
        end
        route_prefix = normalized_route_prefix
      end
      local status = spec.status
      if status ~= nil then
        status = trim(tostring(status)) or ""
        local ok_status_len, status_len_err = validation.check_length(status, 64, "status")
        if not ok_status_len or status == "" then
          return nil, status_len_err or "invalid_format:status"
        end
      end
      out[site_id] = {
        processId = process_id,
        moduleId = module_id,
        scheduler = scheduler_id,
        routePrefix = route_prefix,
        status = status,
      }
    end
  end
  return out
end

local function normalize_dns_proof_state(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:dnsProofState"
  end
  local out = {}
  for host_key, spec in pairs(input) do
    if type(spec) == "table" then
      local host, host_err = normalize_host(host_key, "dnsProofState")
      if not host then
        return nil, host_err
      end
      local proof_state = tostring(spec.state or spec.dnsProofState or "unchecked"):lower()
      if proof_state ~= "valid" and proof_state ~= "expired" and proof_state ~= "missing" and proof_state ~= "unchecked" then
        proof_state = "unchecked"
      end
      local sequence = nil
      if spec.sequence ~= nil or spec.dnsProofSeq ~= nil then
        sequence = tonumber(spec.sequence or spec.dnsProofSeq)
        if not sequence or sequence % 1 ~= 0 or sequence < 0 or sequence > 2147483647 then
          return nil, ("invalid_range:dnsProofState.sequence:%s"):format(host)
        end
      end
      out[host] = {
        state = proof_state,
        checkedAt = spec.checkedAt or spec.dnsProofCheckedAt,
        validUntil = spec.validUntil or spec.dnsProofValidUntil,
        source = spec.source,
        challengeRef = spec.challengeRef,
        sequence = sequence,
      }
    end
  end
  return out
end

local function normalize_method(raw_method, field_name)
  local field = field_name or "Method"
  if type(raw_method) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end
  local method = string.upper(trim(raw_method) or "")
  if method == "" then
    return nil, ("invalid_format:%s"):format(field)
  end
  local ok_len, err_len = validation.check_length(method, MAX_METHOD_BYTES, field)
  if not ok_len then
    return nil, err_len
  end
  if not method:match "^[A-Z]+$" then
    return nil, ("invalid_format:%s"):format(field)
  end
  return method
end

normalize_path = function(raw_path, field_name)
  local field = field_name or "Path"
  if type(raw_path) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end
  local path = trim(raw_path) or ""
  if path == "" then
    path = "/"
  end
  if path:sub(1, 1) ~= "/" then
    path = "/" .. path
  end
  local q_idx = path:find("?", 1, true)
  if q_idx then
    path = path:sub(1, q_idx - 1)
  end
  local h_idx = path:find("#", 1, true)
  if h_idx then
    path = path:sub(1, h_idx - 1)
  end
  if path == "" then
    path = "/"
  end
  local ok_len, err_len = validation.check_length(path, MAX_PATH_BYTES, field)
  if not ok_len then
    return nil, err_len
  end
  if path:find("%s") then
    return nil, ("invalid_format:%s"):format(field)
  end
  return path
end

local function normalize_site_id(raw_site_id, field_name)
  local field = field_name or "Site-Id"
  if type(raw_site_id) ~= "string" then
    return nil, ("invalid_type:%s"):format(field)
  end
  local site_id = trim(raw_site_id) or ""
  if site_id == "" then
    return nil, ("invalid_format:%s"):format(field)
  end
  local ok_len, err_len = validation.check_length(site_id, 128, field)
  if not ok_len then
    return nil, err_len
  end
  return site_id
end

local function normalize_method_set(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:methods"
  end
  local out = {}
  for _, method in ipairs(input) do
    local normalized_method, method_err = normalize_method(method, "methods")
    if not normalized_method then
      return nil, method_err
    end
    out[normalized_method] = true
  end
  return out
end

local function normalize_route_policies(input)
  if input == nil then
    return nil
  end
  if type(input) ~= "table" then
    return nil, "invalid_type:routePolicies"
  end
  local out = {}
  for host_key, spec in pairs(input) do
    if type(spec) == "table" then
      local host, host_err = normalize_host(host_key, "routePolicies")
      if not host then
        return nil, host_err
      end
      local entry = {}
      if spec.defaultActionHint ~= nil then
        local ok_len_hint, err_len_hint =
          validation.check_length(spec.defaultActionHint, 128, "defaultActionHint")
        if not ok_len_hint then
          return nil, err_len_hint
        end
        entry.defaultActionHint = tostring(spec.defaultActionHint)
      end
      entry.rules = {}
      local rules = spec.rules or {}
      if type(rules) ~= "table" then
        return nil, "invalid_type:routePolicies.rules"
      end
      for _, rule in ipairs(rules) do
        if type(rule) == "table" then
          local prefix = rule.pathPrefix or rule.path or "/"
          local normalized_prefix, prefix_err = normalize_path(prefix, "pathPrefix")
          if not normalized_prefix then
            return nil, prefix_err
          end
          local methods, methods_err = normalize_method_set(rule.methods)
          if methods_err then
            return nil, methods_err
          end
          local action_hint = tostring(rule.actionHint or entry.defaultActionHint or "read")
          local ok_len_action, err_len_action = validation.check_length(action_hint, 128, "actionHint")
          if not ok_len_action then
            return nil, err_len_action
          end
          table.insert(entry.rules, {
            pathPrefix = normalized_prefix,
            methods = methods,
            actionHint = action_hint,
          })
        end
      end
      out[host] = entry
    end
  end
  return out
end

local function validate_policy_graph(host_policies, site_policies)
  for host, spec in pairs(host_policies or {}) do
    local site_id = spec and spec.siteId
    if type(site_id) ~= "string" or site_id == "" then
      return nil, ("missing_site_id:hostPolicies.%s"):format(host)
    end
    local site_spec = site_policies and site_policies[site_id] or nil
    local process_id = (spec and spec.processId) or (site_spec and site_spec.processId)
    if type(process_id) ~= "string" or process_id == "" then
      return nil, ("missing_process_mapping:hostPolicies.%s"):format(host)
    end
  end
  return true, nil
end

local function infer_site_process(host, host_policy)
  local site_id = host_policy and host_policy.siteId or nil
  local site_policy = site_id and state.sitePolicies[site_id] or nil

  local site_obj
  local process_obj

  if site_id then
    site_obj = {
      siteId = site_id,
      host = host,
      status = (host_policy and host_policy.status) or (site_policy and site_policy.status) or "unknown",
    }

    local process_id = (host_policy and host_policy.processId) or (site_policy and site_policy.processId)
    if process_id then
      process_obj = {
        processId = process_id,
        moduleId = (host_policy and host_policy.moduleId) or (site_policy and site_policy.moduleId),
        scheduler = (host_policy and host_policy.scheduler) or (site_policy and site_policy.scheduler),
        routePrefix = (host_policy and host_policy.routePrefix) or (site_policy and site_policy.routePrefix),
      }
    end
  end

  return site_obj, process_obj
end

local function default_site_id_from_host(host)
  local token = tostring(host or ""):lower():gsub("[^a-z0-9]+", "-"):gsub("%-+", "-"):gsub("^%-", ""):gsub("%-$", "")
  if token == "" then
    token = "host"
  end
  token = token:sub(1, 96)
  return "site-" .. token
end

local function upsert_host_policy_from_proof(host, msg)
  local site_id, site_err = normalize_site_id(msg["Site-Id"] or msg.SiteId or default_site_id_from_host(host), "Site-Id")
  if not site_id then
    return nil, site_err, "Site-Id"
  end
  local process_id, process_err = normalize_process_identifier(msg["Process-Id"] or msg.ProcessId, "Process-Id")
  if process_err then
    return nil, process_err, "Process-Id"
  end
  if process_id == nil then
    return nil, "missing_field:Process-Id", "Process-Id"
  end
  local module_id, module_err = normalize_process_identifier(msg["Module-Id"] or msg.ModuleId, "Module-Id")
  if module_err then
    return nil, module_err, "Module-Id"
  end
  local scheduler_id, scheduler_err =
    normalize_process_identifier(msg["Scheduler-Id"] or msg.SchedulerId, "Scheduler-Id")
  if scheduler_err then
    return nil, scheduler_err, "Scheduler-Id"
  end
  local route_prefix, route_prefix_err = normalize_path(tostring(msg["Route-Prefix"] or msg.RoutePrefix or "/"), "Route-Prefix")
  if not route_prefix then
    return nil, route_prefix_err, "Route-Prefix"
  end
  local status = trim(tostring(msg.Status or "active")) or "active"
  local ok_status_len, status_len_err = validation.check_length(status, 64, "Status")
  if not ok_status_len or status == "" then
    return nil, status_len_err or "invalid_format:Status", "Status"
  end

  state.hostPolicies[host] = {
    siteId = site_id,
    processId = process_id,
    moduleId = module_id,
    scheduler = scheduler_id,
    routePrefix = route_prefix,
    status = status,
  }

  local existing_site = state.sitePolicies[site_id] or {}
  state.sitePolicies[site_id] = {
    processId = process_id,
    moduleId = module_id or existing_site.moduleId,
    scheduler = scheduler_id or existing_site.scheduler,
    routePrefix = route_prefix or existing_site.routePrefix,
    status = status,
  }

  local default_action_hint = trim(tostring(msg["Action-Hint"] or msg.ActionHint or "")) or ""
  if default_action_hint ~= "" then
    local ok_hint_len, hint_len_err = validation.check_length(default_action_hint, 128, "Action-Hint")
    if not ok_hint_len then
      return nil, hint_len_err, "Action-Hint"
    end
    local route_policy = state.routePolicies[host] or {}
    route_policy.defaultActionHint = default_action_hint
    route_policy.rules = route_policy.rules or {}
    state.routePolicies[host] = route_policy
  end

  return {
    siteId = site_id,
    processId = process_id,
    moduleId = module_id,
    scheduler = scheduler_id,
    routePrefix = route_prefix,
    status = status,
  }, nil, nil
end

local function epoch_to_iso(epoch)
  if not epoch then
    return nil
  end
  return os.date("!%Y-%m-%dT%H:%M:%SZ", epoch)
end

local function iso_to_epoch(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec =
    value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    return nil
  end
  local local_epoch = os.time {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false,
  }
  if not local_epoch then
    return nil
  end
  local local_parts = os.date("*t", local_epoch)
  local utc_parts = os.date("!*t", local_epoch)
  local_parts.isdst = false
  utc_parts.isdst = false
  local offset = os.difftime(os.time(local_parts), os.time(utc_parts))
  return local_epoch + offset
end

local function normalize_proof_state(value)
  if value == nil then
    return nil
  end
  local proof_state = string.lower(trim(tostring(value)) or "")
  if proof_state == "valid" or proof_state == "expired" or proof_state == "missing" or proof_state == "unchecked" then
    return proof_state
  end
  return nil
end

local function build_cache_payload(host_known, proof_payload, surface_key, cache_state, cache_window)
  ensure_cache_hints()
  local ttl = host_known and state.cacheHints.positiveTtlSec or state.cacheHints.negativeTtlSec
  local now_epoch = os.time()
  local expires_epoch = cache_window and cache_window.expiresAtEpoch or (now_epoch + ttl)
  local hard_expire_epoch = cache_window and cache_window.hardExpireEpoch
    or (expires_epoch + state.cacheHints.hardMaxStaleSec)
  local stale_until_epoch = cache_window and cache_window.staleUntilEpoch
    or (expires_epoch + state.cacheHints.staleWhileRevalidateSec)
  if stale_until_epoch > hard_expire_epoch then
    stale_until_epoch = hard_expire_epoch
  end
  local expires_at = epoch_to_iso(expires_epoch)
  local dns_next_check_at = proof_payload.dnsProofValidUntil or epoch_to_iso(now_epoch + state.cacheHints.negativeTtlSec)
  local key_prefix = surface_key or "host"
  local state_value = cache_state or "miss"
  local stale = state_value == "stale"
  local hit = state_value == "hit" or state_value == "negative_hit" or stale
  local negative = state_value == "negative_hit"
  return {
    cacheable = true,
    key = host_known and ("resolver:" .. key_prefix .. ":hit") or ("resolver:" .. key_prefix .. ":miss"),
    cacheState = state_value,
    hit = hit,
    stale = stale,
    staleWhileRevalidate = stale,
    negative = negative,
    ttlSec = ttl,
    expiresAt = expires_at,
    staleUntilAt = epoch_to_iso(stale_until_epoch),
    hardExpiresAt = epoch_to_iso(hard_expire_epoch),
    revalidateAfterAt = expires_at,
    dnsNextCheckAt = dns_next_check_at,
    positiveTtlSec = state.cacheHints.positiveTtlSec,
    negativeTtlSec = state.cacheHints.negativeTtlSec,
    staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
    hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
  }
end

local function make_cache_key(surface, host, path, method, mode)
  local mode_part = mode or "off"
  if surface == "route" then
    return table.concat({ "route", mode_part, host or "", path or "/", method or "GET" }, "|")
  end
  return table.concat({ "host", mode_part, host or "" }, "|")
end

local function get_cached_resolution(cache_key)
  local entry = state.resolutionCache[cache_key]
  if not entry then
    return nil, "miss"
  end
  local now_epoch = os.time()
  local hard_expire_epoch = entry.hardExpireEpoch
  if hard_expire_epoch and now_epoch > hard_expire_epoch then
    state.resolutionCache[cache_key] = nil
    return nil, "miss"
  end
  if entry.expiresAtEpoch and now_epoch <= entry.expiresAtEpoch then
    if entry.negative then
      return entry, "negative_hit"
    end
    return entry, "hit"
  end
  if entry.staleUntilEpoch and now_epoch <= entry.staleUntilEpoch then
    return entry, "stale"
  end
  state.resolutionCache[cache_key] = nil
  return nil, "miss"
end

local function upsert_resolution_cache(cache_key, host, data)
  local now_epoch = os.time()
  local ttl = data.hostKnown and state.cacheHints.positiveTtlSec or state.cacheHints.negativeTtlSec
  local expires_epoch = now_epoch + ttl
  local stale_until_epoch = expires_epoch + state.cacheHints.staleWhileRevalidateSec
  local hard_expire_epoch = expires_epoch + state.cacheHints.hardMaxStaleSec
  if stale_until_epoch > hard_expire_epoch then
    stale_until_epoch = hard_expire_epoch
  end
  state.resolutionCache[cache_key] = {
    cacheKey = cache_key,
    host = host,
    siteId = data.siteId,
    decision = data.decision,
    reasonCode = data.reasonCode,
    mode = data.mode,
    proofState = data.proofState,
    cachedAt = now_iso(),
    expiresAt = epoch_to_iso(expires_epoch),
    expiresAtEpoch = expires_epoch,
    staleUntilAt = epoch_to_iso(stale_until_epoch),
    staleUntilEpoch = stale_until_epoch,
    hardExpireAt = epoch_to_iso(hard_expire_epoch),
    hardExpireEpoch = hard_expire_epoch,
    dnsNextCheckAt = data.dnsNextCheckAt,
    surface = data.surface,
    actionHint = data.actionHint,
    hostKnown = data.hostKnown,
    path = data.path,
    method = data.method,
    process = data.process,
    site = data.site,
    proof = data.proof,
    executionFlow = data.executionFlow,
    negative = data.hostKnown ~= true,
  }
end

local function invalidate_cache_by_host(host)
  local removed = 0
  for key, entry in pairs(state.resolutionCache) do
    if entry and entry.host == host then
      state.resolutionCache[key] = nil
      removed = removed + 1
    end
  end
  return removed
end

local function invalidate_cache_by_site(site_id)
  local removed = 0
  for host, entry in pairs(state.resolutionCache) do
    if entry and entry.siteId == site_id then
      state.resolutionCache[host] = nil
      removed = removed + 1
    end
  end
  return removed
end

local function invalidate_cache_all()
  local removed = 0
  for host, _ in pairs(state.resolutionCache) do
    state.resolutionCache[host] = nil
    removed = removed + 1
  end
  return removed
end

local function prune_resolution_cache()
  local now_epoch = os.time()
  local removed = 0
  local survivors = {}
  local remaining = 0

  for key, entry in pairs(state.resolutionCache) do
    local stale_until_epoch = entry and entry.staleUntilEpoch
    if stale_until_epoch and now_epoch > stale_until_epoch then
      state.resolutionCache[key] = nil
      removed = removed + 1
    else
      remaining = remaining + 1
      table.insert(survivors, { key = key, expiresAtEpoch = entry and entry.expiresAtEpoch or 0 })
    end
  end

  if remaining > RESOLUTION_CACHE_MAX_ENTRIES then
    table.sort(survivors, function(a, b)
      return (a.expiresAtEpoch or 0) < (b.expiresAtEpoch or 0)
    end)
    local overflow = remaining - RESOLUTION_CACHE_MAX_ENTRIES
    for i = 1, overflow do
      local victim = survivors[i]
      if victim and state.resolutionCache[victim.key] ~= nil then
        state.resolutionCache[victim.key] = nil
        removed = removed + 1
      end
    end
  end

  return removed
end

local function refresh_meta_activity_epoch(meta)
  if type(meta) ~= "table" then
    return 0
  end
  local candidates = {
    iso_to_epoch(meta.lastCheckAt),
    iso_to_epoch(meta.nextCheckAt),
    iso_to_epoch(meta.refreshRequestedAt),
    iso_to_epoch(meta.challengeIssuedAt),
    iso_to_epoch(meta.challengeExpiresAt),
  }
  local latest = 0
  for _, epoch in ipairs(candidates) do
    if epoch and epoch > latest then
      latest = epoch
    end
  end
  return latest
end

local function prune_refresh_meta()
  if type(state.refreshMeta) ~= "table" then
    return 0
  end

  local now_epoch = os.time()
  local removed = 0

  if REFRESH_META_STALE_TTL_SEC > 0 then
    for host, meta in pairs(state.refreshMeta) do
      local mapped = state.hostPolicies[host] ~= nil
      local pending_challenge = type(meta.pendingChallenge) == "string" and meta.pendingChallenge ~= ""
      local last_activity = refresh_meta_activity_epoch(meta)
      if not mapped and not pending_challenge and last_activity > 0 and (now_epoch - last_activity) >= REFRESH_META_STALE_TTL_SEC then
        state.refreshMeta[host] = nil
        removed = removed + 1
      end
    end
  end

  if REFRESH_META_MAX_HOSTS <= 0 then
    if removed > 0 then
      refresh_state_mutated = true
    end
    return removed
  end

  local count = 0
  local entries = {}
  for host, meta in pairs(state.refreshMeta) do
    count = count + 1
    local mapped = state.hostPolicies[host] ~= nil
    local pending_challenge = type(meta.pendingChallenge) == "string" and meta.pendingChallenge ~= ""
    local priority = 0
    if mapped then
      priority = priority + 2
    end
    if pending_challenge then
      priority = priority + 1
    end
    entries[#entries + 1] = {
      host = host,
      priority = priority,
      activity = refresh_meta_activity_epoch(meta),
    }
  end

  if count > REFRESH_META_MAX_HOSTS then
    local overflow = count - REFRESH_META_MAX_HOSTS
    table.sort(entries, function(a, b)
      if a.priority ~= b.priority then
        return a.priority < b.priority
      end
      if a.activity ~= b.activity then
        return a.activity < b.activity
      end
      return a.host < b.host
    end)

    for i = 1, overflow do
      local victim = entries[i]
      if victim and state.refreshMeta[victim.host] ~= nil then
        state.refreshMeta[victim.host] = nil
        removed = removed + 1
      end
    end
  end

  if removed > 0 then
    refresh_state_mutated = true
  end
  return removed
end

local function maybe_persist_state(force)
  local now_epoch = os.time()
  local min_interval = math.max(0, RESOLVER_PERSIST_MIN_INTERVAL_SEC)
  if force or min_interval == 0 or (now_epoch - last_persist_epoch) >= min_interval then
    persist.save("resolver_state", state)
    last_persist_epoch = now_epoch
  end
end

local function build_proof_payload(host)
  local proof = state.dnsProofState[host]
  if not proof then
    return {
      dnsProofState = "unchecked",
      dnsProofCheckedAt = nil,
      dnsProofValidUntil = nil,
      source = "resolver-cache",
    }
  end
  return {
    dnsProofState = proof.state or "unchecked",
    dnsProofCheckedAt = proof.checkedAt,
    dnsProofValidUntil = proof.validUntil,
    source = proof.source or "resolver-cache",
    challengeRef = proof.challengeRef,
    dnsProofSeq = proof.sequence,
  }
end

local function evaluate_dns_proof_decision(mode, host_known, proof_state)
  local decision = "allow"
  local reason

  if not host_known then
    return decision, nil
  end

  if proof_state == "valid" then
    return decision, "ALLOW_DNS_PROOF_VALID"
  end

  if proof_state == "expired" then
    if mode == "off" then
      return decision, "ALLOW_DNS_PROOF_EXPIRED_MODE_OFF"
    end
    if mode == "observe" then
      return decision, "ALLOW_DNS_PROOF_EXPIRED_MODE_OBSERVE"
    end
    reason = "DENY_READY_DNS_PROOF_EXPIRED"
  elseif proof_state == "missing" then
    if mode == "off" then
      return decision, "ALLOW_DNS_PROOF_MISSING_MODE_OFF"
    end
    if mode == "observe" then
      return decision, "ALLOW_DNS_PROOF_MISSING_MODE_OBSERVE"
    end
    reason = "DENY_READY_DNS_PROOF_MISSING"
  elseif proof_state == "unchecked" then
    if mode == "off" then
      return decision, "ALLOW_DNS_PROOF_UNCHECKED_MODE_OFF"
    end
    if mode == "observe" then
      return decision, "ALLOW_DNS_PROOF_UNCHECKED_MODE_OBSERVE"
    end
    reason = "DENY_READY_DNS_PROOF_UNCHECKED"
  else
    return decision, nil
  end

  if state.failOpen == false then
    decision = "deny"
  end
  return decision, reason
end

local function evaluate_route_decision(mode, host_known, proof_state)
  if not host_known then
    if mode == "off" then
      return "allow", "ALLOW_ROUTE_HOST_UNMAPPED_MODE_OFF"
    end
    if mode == "observe" then
      return "allow", "ALLOW_ROUTE_HOST_UNMAPPED_MODE_OBSERVE"
    end
    if state.failOpen == false then
      return "deny", "DENY_READY_ROUTE_HOST_UNMAPPED"
    end
    return "allow", "DENY_READY_ROUTE_HOST_UNMAPPED"
  end

  local decision, reason = evaluate_dns_proof_decision(mode, true, proof_state)
  if reason then
    return decision, reason
  end
  return "allow", "ALLOW_ROUTE_HOST_BOUND"
end

local function evaluate_host_decision(mode, host_known, proof_state)
  if not host_known then
    if mode == "off" then
      return "allow", "ALLOW_HOST_UNMAPPED_MODE_OFF"
    end
    if mode == "observe" then
      return "allow", "ALLOW_HOST_UNMAPPED_MODE_OBSERVE"
    end
    if state.failOpen == false then
      return "deny", "DENY_READY_HOST_UNMAPPED"
    end
    return "allow", "DENY_READY_HOST_UNMAPPED"
  end

  local decision, reason = evaluate_dns_proof_decision(mode, true, proof_state)
  if reason then
    return decision, reason
  end
  return "allow", "ALLOW_HOST_BOUND"
end

local function starts_with(text, prefix)
  return text:sub(1, #prefix) == prefix
end

local function infer_action_hint(path, method)
  if method == "GET" or method == "HEAD" then
    if starts_with(path, "/~process@1.0/")
      or starts_with(path, "/~scheduler@1.0/")
      or starts_with(path, "/~meta@1.0/")
      or starts_with(path, "/~relay@1.0/")
    then
      return "control_plane"
    end
    return "read"
  end
  if method == "OPTIONS" then
    return "preflight"
  end
  return "write"
end

local function resolve_action_hint(host, path, method, host_policy)
  local hint_source = "inferred"
  local site_id = host_policy and host_policy.siteId or nil
  local site_policy = site_id and state.sitePolicies[site_id] or nil
  local route_policy = state.routePolicies[host]

  if route_policy and type(route_policy.rules) == "table" then
    for _, rule in ipairs(route_policy.rules) do
      if starts_with(path, rule.pathPrefix) then
        local methods = rule.methods
        if methods == nil or methods[method] then
          return rule.actionHint or infer_action_hint(path, method), "route_policy_rule"
        end
      end
    end
    if route_policy.defaultActionHint then
      return route_policy.defaultActionHint, "route_policy_default"
    end
  end

  if host_policy and host_policy.actionHint then
    return tostring(host_policy.actionHint), "host_policy"
  end
  if site_policy and site_policy.defaultActionHint then
    return tostring(site_policy.defaultActionHint), "site_policy"
  end
  return infer_action_hint(path, method), hint_source
end

local function deny_ready(reason_code)
  return type(reason_code) == "string" and reason_code:match("^DENY_READY_") ~= nil
end

local function with_result_envelope(payload)
  payload.result = {
    decision = payload.decision,
    reasonCode = payload.reasonCode,
    status = payload.decision == "deny" and "DENY" or "ALLOW",
  }
  payload.reason = payload.reasonCode
  payload.policy = {
    mode = payload.mode,
    failOpen = state.failOpen ~= false,
    enforceMode = payload.mode == "enforce",
    denyReady = deny_ready(payload.reasonCode),
  }
  return payload
end

local function payload_from_cached_entry(entry, request_id, node_id, cache_state, refresh_payload)
  local proof_payload = entry.proof
    or {
      dnsProofState = entry.proofState or "unchecked",
      dnsProofCheckedAt = nil,
      dnsProofValidUntil = nil,
      source = "resolver-cache",
    }
  local cache_window = {
    expiresAtEpoch = entry.expiresAtEpoch,
    staleUntilEpoch = entry.staleUntilEpoch,
    hardExpireEpoch = entry.hardExpireEpoch,
  }
  local payload = {
    schemaVersion = "1.0",
    requestId = request_id,
    decision = entry.decision,
    reasonCode = entry.reasonCode,
    mode = entry.mode,
    host = entry.host,
    nodeId = node_id,
    cache = build_cache_payload(entry.hostKnown == true, proof_payload, entry.surface, cache_state, cache_window),
    proof = proof_payload,
  }
  if entry.path then
    payload.path = entry.path
  end
  if entry.method then
    payload.method = entry.method
  end
  if entry.site then
    payload.site = entry.site
  elseif entry.siteId then
    payload.site = { siteId = entry.siteId, host = entry.host, status = "unknown" }
  end
  if entry.process then
    payload.process = entry.process
  end
  if entry.actionHint ~= nil then
    payload.routeHint = {
      source = "cache",
    }
    payload.routeHint.actionHint = entry.actionHint
    if entry.executionFlow ~= nil then
      payload.routeHint.executionFlow = entry.executionFlow
    end
  elseif entry.executionFlow ~= nil and entry.surface == "route" then
    payload.routeHint = {
      source = "cache",
      executionFlow = entry.executionFlow,
    }
  elseif entry.executionFlow ~= nil then
    payload.executionFlow = entry.executionFlow
  end
  if refresh_payload ~= nil then
    payload.refresh = refresh_payload
  end
  return with_result_envelope(payload)
end

local function parse_int_field(raw_value, field_name, min_value, max_value)
  local value = tonumber(raw_value)
  if not value or value % 1 ~= 0 then
    return nil, ("invalid_number:%s"):format(field_name)
  end
  if value < min_value or value > max_value then
    return nil, ("invalid_range:%s"):format(field_name)
  end
  return value, nil
end

local function build_refresh_meta(host, now_epoch)
  local meta = state.refreshMeta[host]
  local proof = state.dnsProofState[host]
  local next_check_epoch = nil

  if meta and type(meta.nextCheckAt) == "string" then
    next_check_epoch = iso_to_epoch(meta.nextCheckAt)
  end
  if next_check_epoch == nil and proof and type(proof.validUntil) == "string" then
    next_check_epoch = iso_to_epoch(proof.validUntil)
  end
  if next_check_epoch == nil then
    next_check_epoch = now_epoch
  end

  return {
    host = host,
    dnsProofState = proof and proof.state or "unchecked",
    lastCheckAt = meta and meta.lastCheckAt or nil,
    nextCheckAt = epoch_to_iso(next_check_epoch),
    nextCheckEpoch = next_check_epoch,
    retryCount = meta and tonumber(meta.retryCount or 0) or 0,
    lastError = meta and meta.lastError or nil,
    refreshRequestedAt = meta and meta.refreshRequestedAt or nil,
    lastRequestedReason = meta and meta.lastRequestedReason or nil,
    requestCount = meta and tonumber(meta.requestCount or 0) or 0,
    pendingChallenge = meta and meta.pendingChallenge or nil,
    challengeExpiresAt = meta and meta.challengeExpiresAt or nil,
  }
end

local function refresh_paths_snapshot()
  return {
    relayPath = state.autoDns.relayPath,
    cachePath = state.autoDns.cachePath,
    cronPath = state.autoDns.cronPath,
  }
end

local function refresh_endpoints_snapshot()
  return {
    dohEndpoint = state.autoDns.dohEndpoint,
    arweaveBase = state.autoDns.arweaveBase,
  }
end

local function execution_flow_snapshot()
  return {
    mode = state.executionFlow.mode,
    preflightSchedule = state.executionFlow.preflightSchedule ~= false,
    requireNumericSlot = state.executionFlow.requireNumericSlot ~= false,
    singleFlightPerProcess = state.executionFlow.singleFlightPerProcess ~= false,
    maxAttempts = tonumber(state.executionFlow.maxAttempts) or 5,
    baseBackoffMs = tonumber(state.executionFlow.baseBackoffMs) or 300,
    maxBackoffMs = tonumber(state.executionFlow.maxBackoffMs) or 1000,
  }
end

local function build_execution_flow_hint(process_obj)
  local snapshot = execution_flow_snapshot()
  local hint = {
    mode = snapshot.mode,
    preflightSchedule = snapshot.preflightSchedule,
    requireNumericSlot = snapshot.requireNumericSlot,
    singleFlightPerProcess = snapshot.singleFlightPerProcess,
    strategy = "slot_pinned_scheduler_preflight",
    retry = {
      maxAttempts = snapshot.maxAttempts,
      baseBackoffMs = snapshot.baseBackoffMs,
      maxBackoffMs = snapshot.maxBackoffMs,
    },
    templates = {
      schedulerPreflight = "/~scheduler@1.0/schedule?target=<PROCESS_ID>",
      slotPinnedCompute = "/~process@1.0/compute?target=<PROCESS_ID>&slot=<SLOT>",
      slotPinnedRead = "/~process@1.0/read?target=<PROCESS_ID>&slot=<SLOT>",
    },
  }
  if type(process_obj) == "table" then
    if type(process_obj.processId) == "string" and process_obj.processId ~= "" then
      hint.targetProcessId = process_obj.processId
    end
    if type(process_obj.scheduler) == "string" and process_obj.scheduler ~= "" then
      hint.scheduler = process_obj.scheduler
    end
  end
  return hint
end

local function list_tracked_hosts()
  local tracked = {}
  for host, _ in pairs(state.hostPolicies or {}) do
    tracked[host] = true
  end
  for host, _ in pairs(state.refreshMeta or {}) do
    tracked[host] = true
  end
  return tracked
end

local function evaluate_admission(host)
  if type(host) ~= "string" or host == "" then
    return "deny", "DENY_ADMISSION_INVALID_HOST"
  end
  local admission = state.admission or {}
  local deny_hosts = admission.denyHosts or {}
  local deny_entry = deny_hosts[host]
  if deny_entry ~= nil then
    local reason = type(deny_entry) == "table" and deny_entry.reason or nil
    return "deny", reason or "DENY_ADMISSION_BLOCKLIST"
  end
  if admission.allowlistEnabled == true then
    local allow_hosts = admission.allowHosts or {}
    if allow_hosts[host] == nil then
      return "deny", "DENY_ADMISSION_ALLOWLIST_MISS"
    end
  end
  return "allow", "ALLOW_ADMISSION_OK"
end

local function normalize_challenge_ref(raw_value, field_name)
  if raw_value == nil then
    return nil
  end
  if type(raw_value) ~= "string" then
    return nil, ("invalid_type:%s"):format(field_name)
  end
  local value = trim(raw_value) or ""
  if value == "" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  local ok_len, err_len = validation.check_length(value, 256, field_name)
  if not ok_len then
    return nil, err_len
  end
  if not value:match "^[A-Za-z0-9%._:%-]+$" then
    return nil, ("invalid_format:%s"):format(field_name)
  end
  return value
end

local challenge_nonce_counter = 0

local function bytes_to_hex(bytes)
  if type(bytes) ~= "string" then
    return nil
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", string.byte(c))
  end))
end

local function secure_nonce_hex(byte_len)
  local n = tonumber(byte_len) or 16
  if n < 8 then
    n = 8
  end
  if n > 64 then
    n = 64
  end

  if openssl_ok and openssl and openssl.rand and type(openssl.rand.bytes) == "function" then
    local ok_rand, raw = pcall(openssl.rand.bytes, n)
    if ok_rand and type(raw) == "string" and #raw > 0 then
      return bytes_to_hex(raw)
    end
  end

  challenge_nonce_counter = challenge_nonce_counter + 1
  local fallback =
    string.format("%x%x%x", os.time(), challenge_nonce_counter, math.floor((os.clock() or 0) * 1000000000))
  fallback = fallback:gsub("[^a-f0-9]", "")
  if fallback == "" then
    fallback = tostring(os.time()) .. tostring(challenge_nonce_counter)
  end
  return fallback
end

local function mint_challenge_ref(host, reason, now_epoch)
  local host_token = (host or "host"):gsub("[^a-z0-9]+", "-")
  if host_token == "" then
    host_token = "host"
  end
  host_token = host_token:sub(1, 48)
  local reason_token = (reason or "refresh"):gsub("[^a-z0-9]+", "-")
  if reason_token == "" then
    reason_token = "refresh"
  end
  reason_token = reason_token:sub(1, 32)
  local nonce = secure_nonce_hex(16) or tostring(now_epoch or os.time())
  return string.format("dm1:%s:%s:%s", host_token, reason_token, nonce)
end

local function issue_refresh_challenge(host, reason, ttl_sec, explicit_challenge_ref)
  local now_epoch = os.time()
  local now_iso_value = epoch_to_iso(now_epoch)
  local ttl = tonumber(ttl_sec) or tonumber(state.autoDns.challengeTtlSec) or 300
  if ttl < 30 then
    ttl = 30
  end
  if ttl > 7200 then
    ttl = 7200
  end
  local challenge_ref = explicit_challenge_ref or mint_challenge_ref(host, reason, now_epoch)
  local expires_at = epoch_to_iso(now_epoch + ttl)
  local meta = state.refreshMeta[host] or {}
  meta.pendingChallenge = challenge_ref
  meta.challengeIssuedAt = now_iso_value
  meta.challengeExpiresAt = expires_at
  meta.lastRequestedReason = reason or meta.lastRequestedReason
  state.refreshMeta[host] = meta
  refresh_state_mutated = true
  return challenge_ref, expires_at, ttl
end

local function validate_refresh_challenge(host, challenge_ref, now_epoch)
  if state.autoDns.requireChallenge ~= true then
    return true
  end
  if challenge_ref == nil or challenge_ref == "" then
    return false, "missing_field:Challenge-Ref"
  end
  local meta = state.refreshMeta[host]
  local expected = meta and meta.pendingChallenge
  if type(expected) ~= "string" or expected == "" then
    return false, "challenge_not_issued"
  end
  if expected ~= challenge_ref then
    return false, "challenge_mismatch"
  end
  local expires_epoch = iso_to_epoch(meta and meta.challengeExpiresAt)
  if expires_epoch ~= nil and expires_epoch < (now_epoch or os.time()) then
    return false, "challenge_expired"
  end
  return true
end

local function clear_refresh_challenge(host)
  local meta = state.refreshMeta[host]
  if not meta then
    return
  end
  meta.pendingChallenge = nil
  meta.challengeIssuedAt = nil
  meta.challengeExpiresAt = nil
  state.refreshMeta[host] = meta
end

local function maybe_queue_refresh_from_access(host, proof_payload, host_known, cache_state)
  if state.autoDns.enabled ~= true then
    return nil
  end

  local reason = nil
  if host_known ~= true then
    reason = "host_unmapped"
  end
  if cache_state == "stale" and state.autoDns.refreshOnStale == true then
    reason = "cache_stale"
  elseif reason == nil then
    local proof_state = proof_payload and proof_payload.dnsProofState or "unchecked"
    if proof_state ~= "valid" then
      reason = "proof_" .. proof_state
    else
      local valid_until_epoch = iso_to_epoch(proof_payload and proof_payload.dnsProofValidUntil)
      if valid_until_epoch and valid_until_epoch <= os.time() then
        reason = "proof_due"
      end
    end
  end

  if reason == nil then
    return nil
  end

  local now_epoch = os.time()
  local now_iso_value = epoch_to_iso(now_epoch)
  local min_interval = state.autoDns.staleRefreshMinIntervalSec or 0
  local meta = state.refreshMeta[host] or {}
  local effective_next = meta.nextCheckAt

  if not request_allows_refresh_queue_mutation then
    return {
      enabled = true,
      requested = false,
      reason = reason,
      source = "read_only",
      nextCheckAt = effective_next,
      refreshRequestedAt = meta.refreshRequestedAt,
      retryCount = tonumber(meta.retryCount) or 0,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeRef = meta.pendingChallenge,
      challengeExpiresAt = meta.challengeExpiresAt,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    }
  end

  local last_requested_epoch = iso_to_epoch(meta.refreshRequestedAt)
  local should_request = last_requested_epoch == nil or (now_epoch - last_requested_epoch) >= min_interval

  if should_request then
    meta.refreshRequestedAt = now_iso_value
    meta.lastRequestedReason = reason
    meta.requestCount = (tonumber(meta.requestCount) or 0) + 1
    local next_check_epoch = iso_to_epoch(meta.nextCheckAt)
    if next_check_epoch == nil or next_check_epoch > now_epoch then
      meta.nextCheckAt = now_iso_value
    end
    state.refreshMeta[host] = meta
    refresh_state_mutated = true
    if state.autoDns.requireChallenge == true then
      local issued_ref, issued_expires_at =
        issue_refresh_challenge(host, reason, state.autoDns.challengeTtlSec)
      meta = state.refreshMeta[host] or meta
      meta.pendingChallenge = issued_ref
      meta.challengeExpiresAt = issued_expires_at
      state.refreshMeta[host] = meta
    end
  end

  if effective_next == nil then
    effective_next = plus_seconds_iso(state.autoDns.refreshIntervalSec)
    state.refreshMeta[host] = meta
    state.refreshMeta[host].nextCheckAt = effective_next
    refresh_state_mutated = true
  end

  return {
    enabled = true,
    requested = should_request,
    reason = reason,
    source = should_request and "on_access" or "cooldown",
    nextCheckAt = effective_next,
    refreshRequestedAt = meta.refreshRequestedAt,
    retryCount = tonumber(meta.retryCount) or 0,
    staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
    requireChallenge = state.autoDns.requireChallenge == true,
    challengeRef = meta.pendingChallenge,
    challengeExpiresAt = meta.challengeExpiresAt,
    paths = refresh_paths_snapshot(),
    endpoints = refresh_endpoints_snapshot(),
  }
end

function handlers.ApplyPolicyBundle(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Bundle",
    "bundle",
    "Policy-Mode",
    "PolicyMode",
    "Fail-Open",
    "FailOpen",
    "Cache-Hints",
    "CacheHints",
    "Execution-Flow",
    "ExecutionFlow",
    "Auto-Dns",
    "AutoDns",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local bundle = msg.Bundle or msg.bundle
  if bundle ~= nil and type(bundle) ~= "table" then
    return codec.error("INVALID_INPUT", "Bundle must be an object", { field = "Bundle" })
  end
  bundle = bundle or {}

  local mode_source = bundle.policyMode or bundle.mode or msg["Policy-Mode"] or msg.PolicyMode
  local mode, mode_fallback_reason = normalize_mode(mode_source)
  if mode_fallback_reason and mode_source ~= nil then
    return codec.error("INVALID_INPUT", "Invalid policy mode", { field = "Policy-Mode" })
  end

  local fail_open_source = bundle.failOpen
  if fail_open_source == nil then
    fail_open_source = msg["Fail-Open"] or msg.FailOpen
  end
  local fail_open, fail_open_err = parse_fail_open(fail_open_source, state.failOpen ~= false)
  if fail_open == nil then
    return codec.error("INVALID_INPUT", fail_open_err, { field = "Fail-Open" })
  end

  local cache_hints_source = bundle.cacheHints or msg["Cache-Hints"] or msg.CacheHints
  local cache_hints_update, cache_err = normalize_cache_hints(cache_hints_source)
  if cache_err then
    return codec.error("INVALID_INPUT", cache_err, { field = "Cache-Hints" })
  end

  local execution_flow_source = bundle.executionFlow or bundle["Execution-Flow"] or msg["Execution-Flow"] or msg.ExecutionFlow
  local execution_flow_update, execution_flow_err = normalize_execution_flow(execution_flow_source)
  if execution_flow_err then
    return codec.error("INVALID_INPUT", execution_flow_err, { field = "Execution-Flow" })
  end

  local auto_dns_source = bundle.autoDns or msg["Auto-Dns"] or msg.AutoDns
  local auto_dns_update, auto_dns_err = normalize_auto_dns(auto_dns_source)
  if auto_dns_err then
    return codec.error("INVALID_INPUT", auto_dns_err, { field = "Auto-Dns" })
  end

  local host_input = bundle.hostPolicies or bundle.hosts or msg["Host-Policies"] or msg.HostPolicies
  local site_input = bundle.sitePolicies or bundle.sites or msg["Site-Policies"] or msg.SitePolicies
  local route_input = bundle.routePolicies or bundle.routes or msg["Route-Policies"] or msg.RoutePolicies
  local dns_input = bundle.dnsProofState or bundle.dnsProof or msg["DNS-Proof-State"] or msg.DnsProofState

  local normalized_hosts, hosts_err = normalize_host_policies(host_input)
  if hosts_err then
    return codec.error("INVALID_INPUT", hosts_err, { field = "hostPolicies" })
  end
  local normalized_sites, sites_err = normalize_site_policies(site_input)
  if sites_err then
    return codec.error("INVALID_INPUT", sites_err, { field = "sitePolicies" })
  end
  local normalized_dns, dns_err = normalize_dns_proof_state(dns_input)
  if dns_err then
    return codec.error("INVALID_INPUT", dns_err, { field = "dnsProofState" })
  end
  local normalized_routes, routes_err = normalize_route_policies(route_input)
  if routes_err then
    return codec.error("INVALID_INPUT", routes_err, { field = "routePolicies" })
  end

  if not ALLOW_CENTRALIZED_BUNDLE_WRITES then
    local blocked_fields = {}
    if normalized_hosts ~= nil then
      table.insert(blocked_fields, "hostPolicies")
    end
    if normalized_sites ~= nil then
      table.insert(blocked_fields, "sitePolicies")
    end
    if normalized_routes ~= nil then
      table.insert(blocked_fields, "routePolicies")
    end
    if normalized_dns ~= nil then
      table.insert(blocked_fields, "dnsProofState")
    end

    if #blocked_fields > 0 then
      return codec.error(
        "FORBIDDEN",
        "centralized_bundle_writes_disabled",
        {
          fields = blocked_fields,
          hint = "Use DNS TXT + AR config + proof refresh flow (or set RESOLVER_ALLOW_CENTRALIZED_BUNDLE_WRITES=1).",
        }
      )
    end
  end

  local candidate_hosts = normalized_hosts or state.hostPolicies
  local candidate_sites = normalized_sites or state.sitePolicies
  local graph_ok, graph_err = validate_policy_graph(candidate_hosts, candidate_sites)
  if not graph_ok then
    return codec.error("INVALID_INPUT", graph_err, { field = "hostPolicies" })
  end

  if normalized_hosts ~= nil then
    state.hostPolicies = normalized_hosts
  end
  if normalized_sites ~= nil then
    state.sitePolicies = normalized_sites
  end
  if normalized_routes ~= nil then
    state.routePolicies = normalized_routes
  end
  if normalized_dns ~= nil then
    state.dnsProofState = normalized_dns
  end

  state.policyMode = mode
  state.failOpen = fail_open
  ensure_cache_hints()
  local next_cache_hints = {
    positiveTtlSec = state.cacheHints.positiveTtlSec,
    negativeTtlSec = state.cacheHints.negativeTtlSec,
    staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
    hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
  }
  if cache_hints_update then
    for key, value in pairs(cache_hints_update) do
      next_cache_hints[key] = value
    end
  end
  if next_cache_hints.hardMaxStaleSec < next_cache_hints.staleWhileRevalidateSec then
    return codec.error("INVALID_INPUT", "invalid_relation:hardMaxStaleSec", { field = "Cache-Hints" })
  end
  state.cacheHints = next_cache_hints
  local next_execution_flow = execution_flow_snapshot()
  if execution_flow_update then
    for key, value in pairs(execution_flow_update) do
      next_execution_flow[key] = value
    end
  end
  if next_execution_flow.maxBackoffMs < next_execution_flow.baseBackoffMs then
    return codec.error("INVALID_INPUT", "invalid_relation:Execution-Flow.maxBackoffMs", { field = "Execution-Flow" })
  end
  state.executionFlow = next_execution_flow
  if auto_dns_update then
    local next_auto_dns = {}
    for key, value in pairs(state.autoDns) do
      next_auto_dns[key] = value
    end
    for key, value in pairs(auto_dns_update) do
      next_auto_dns[key] = value
    end
    state.autoDns = next_auto_dns
  end

  local snapshot_id = bundle.snapshotId or msg["Snapshot-Id"] or msg.SnapshotId
  local version = bundle.version or msg.Version
  local generated_at = bundle.generatedAt or msg["Generated-At"] or msg.GeneratedAt

  state.bundleMeta = state.bundleMeta or {}
  state.bundleMeta.snapshotId = snapshot_id or state.bundleMeta.snapshotId
  state.bundleMeta.version = version or state.bundleMeta.version
  state.bundleMeta.generatedAt = generated_at or state.bundleMeta.generatedAt
  state.bundleMeta.appliedAt = now_iso()
  local purged_entries = invalidate_cache_all()
  state.cacheMeta.lastInvalidatedAt = state.bundleMeta.appliedAt

  return codec.ok {
    schemaVersion = "1.0",
    applied = true,
    appliedAt = state.bundleMeta.appliedAt,
    policyMode = state.policyMode,
    failOpen = state.failOpen,
    bundleMeta = state.bundleMeta,
    cacheInvalidation = {
      scope = "all",
      purgedEntries = purged_entries,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
    counts = {
      hostPolicies = map_count(state.hostPolicies),
      sitePolicies = map_count(state.sitePolicies),
      routePolicies = map_count(state.routePolicies),
      dnsProofState = map_count(state.dnsProofState),
    },
    cacheHints = {
      positiveTtlSec = state.cacheHints.positiveTtlSec,
      negativeTtlSec = state.cacheHints.negativeTtlSec,
      staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
      hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
    },
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    executionFlow = execution_flow_snapshot(),
  }
end

function handlers.InvalidateResolverCache(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Scope",
    "Host",
    "Site-Id",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local scope = string.lower(tostring(msg.Scope or "all"))
  local removed = 0
  local target = nil

  if scope == "all" then
    removed = invalidate_cache_all()
  elseif scope == "host" then
    local ok_fields, missing = validation.require_fields(msg, { "Host" })
    if not ok_fields then
      return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
    end
    local host, host_err = normalize_host(msg.Host, "Host")
    if not host then
      return codec.error("INVALID_INPUT", host_err, { field = "Host" })
    end
    target = host
    removed = invalidate_cache_by_host(host)
  elseif scope == "site" then
    local ok_fields, missing = validation.require_fields(msg, { "Site-Id" })
    if not ok_fields then
      return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
    end
    local site_id, site_err = normalize_site_id(msg["Site-Id"], "Site-Id")
    if not site_id then
      return codec.error("INVALID_INPUT", site_err, { field = "Site-Id" })
    end
    target = site_id
    removed = invalidate_cache_by_site(site_id)
  else
    return codec.error("INVALID_INPUT", "Invalid scope", { field = "Scope", allowed = { "all", "host", "site" } })
  end

  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    invalidated = true,
    scope = scope,
    target = target,
    removedEntries = removed,
    remainingEntries = map_count(state.resolutionCache),
    lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
  }
end

function handlers.GetResolverCacheStats(_msg)
  local mapped = 0
  local unmapped = 0
  local by_proof = {
    valid = 0,
    expired = 0,
    missing = 0,
    unchecked = 0,
    other = 0,
  }
  for _, entry in pairs(state.resolutionCache) do
    if entry and entry.siteId and entry.siteId ~= "" then
      mapped = mapped + 1
    else
      unmapped = unmapped + 1
    end
    local proof_state = (entry and entry.proofState) or "unchecked"
    if by_proof[proof_state] ~= nil then
      by_proof[proof_state] = by_proof[proof_state] + 1
    else
      by_proof.other = by_proof.other + 1
    end
  end

  return codec.ok {
    schemaVersion = "1.0",
    counts = {
      entriesTotal = map_count(state.resolutionCache),
      mappedHosts = mapped,
      unmappedHosts = unmapped,
    },
    byProofState = by_proof,
    lastAppliedAt = state.bundleMeta and state.bundleMeta.appliedAt or nil,
    lastResolvedAt = state.lastResolvedAt,
    lastInvalidatedAt = state.cacheMeta and state.cacheMeta.lastInvalidatedAt or nil,
  }
end

function handlers.GetDnsRefreshState(_msg)
  local now_epoch = os.time()
  local tracked_hosts = 0
  local due_now = 0
  local with_errors = 0
  local with_pending_request = 0
  local with_pending_challenge = 0

  for host, _ in pairs(list_tracked_hosts()) do
    tracked_hosts = tracked_hosts + 1
    local meta = build_refresh_meta(host, now_epoch)
    if meta.nextCheckEpoch <= now_epoch then
      due_now = due_now + 1
    end
    if meta.lastError ~= nil and meta.lastError ~= "" then
      with_errors = with_errors + 1
    end
    if meta.refreshRequestedAt ~= nil then
      with_pending_request = with_pending_request + 1
    end
    if meta.pendingChallenge ~= nil and meta.pendingChallenge ~= "" then
      with_pending_challenge = with_pending_challenge + 1
    end
  end

  return codec.ok {
    schemaVersion = "1.0",
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    counts = {
      trackedHosts = tracked_hosts,
      dueNow = due_now,
      withErrors = with_errors,
      withPendingRequest = with_pending_request,
      withPendingChallenge = with_pending_challenge,
    },
    generatedAt = now_iso(),
  }
end

function handlers.ListHostsDueForDnsRefresh(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Limit",
    "Now-Epoch",
    "NowEpoch",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local now_epoch = os.time()
  local now_override = msg["Now-Epoch"] or msg.NowEpoch
  if now_override ~= nil then
    local parsed_now, parsed_now_err = parse_int_field(now_override, "Now-Epoch", 0, 4102444800)
    if parsed_now_err then
      return codec.error("INVALID_INPUT", parsed_now_err, { field = "Now-Epoch" })
    end
    now_epoch = parsed_now
  end

  local limit = state.autoDns.maxHostsPerRun
  local limit_raw = msg.Limit
  if limit_raw ~= nil then
    local parsed_limit, parsed_limit_err = parse_int_field(limit_raw, "Limit", 1, 500)
    if parsed_limit_err then
      return codec.error("INVALID_INPUT", parsed_limit_err, { field = "Limit" })
    end
    limit = parsed_limit
  end

  local due = {}
  local tracked_hosts = 0
  for host, _ in pairs(list_tracked_hosts()) do
    tracked_hosts = tracked_hosts + 1
    local host_policy = state.hostPolicies[host]
    local meta = build_refresh_meta(host, now_epoch)
    if meta.nextCheckEpoch <= now_epoch then
      table.insert(due, {
        host = host,
        siteId = host_policy and host_policy.siteId or nil,
        dnsProofState = meta.dnsProofState,
        nextCheckAt = meta.nextCheckAt,
        lastCheckAt = meta.lastCheckAt,
        retryCount = meta.retryCount,
        lastError = meta.lastError,
        refreshRequestedAt = meta.refreshRequestedAt,
        lastRequestedReason = meta.lastRequestedReason,
        requestCount = meta.requestCount,
        challengeRef = meta.pendingChallenge,
        challengeExpiresAt = meta.challengeExpiresAt,
      })
    end
  end

  table.sort(due, function(a, b)
    local left_epoch = iso_to_epoch(a.nextCheckAt) or 0
    local right_epoch = iso_to_epoch(b.nextCheckAt) or 0
    if left_epoch == right_epoch then
      return (a.host or "") < (b.host or "")
    end
    return left_epoch < right_epoch
  end)

  if #due > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = due[i]
    end
    due = limited
  end

  return codec.ok {
    schemaVersion = "1.0",
    generatedAt = now_iso(),
    nowEpoch = now_epoch,
    limit = limit,
    counts = {
      trackedHosts = tracked_hosts,
      returned = #due,
    },
    dueHosts = due,
  }
end

function handlers.RunAutoDnsTick(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Limit",
    "Now-Epoch",
    "NowEpoch",
    "Reason",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local now_epoch = os.time()
  local now_override = msg["Now-Epoch"] or msg.NowEpoch
  if now_override ~= nil then
    local parsed_now, parsed_now_err = parse_int_field(now_override, "Now-Epoch", 0, 4102444800)
    if parsed_now_err then
      return codec.error("INVALID_INPUT", parsed_now_err, { field = "Now-Epoch" })
    end
    now_epoch = parsed_now
  end

  local reason = trim(tostring(msg.Reason or "cron_tick")) or "cron_tick"
  local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
  if not ok_reason_len or reason == "" then
    return codec.error("INVALID_INPUT", reason_len_err or "invalid_format:Reason", { field = "Reason" })
  end

  local limit = state.autoDns.maxHostsPerRun
  local limit_raw = msg.Limit
  if limit_raw ~= nil then
    local parsed_limit, parsed_limit_err = parse_int_field(limit_raw, "Limit", 1, 500)
    if parsed_limit_err then
      return codec.error("INVALID_INPUT", parsed_limit_err, { field = "Limit" })
    end
    limit = parsed_limit
  end

  local due = {}
  local tracked_hosts = 0
  local due_now = 0
  local queued_now = 0
  local now_iso_value = epoch_to_iso(now_epoch)
  local min_interval = state.autoDns.staleRefreshMinIntervalSec or 0

  for host, _ in pairs(list_tracked_hosts()) do
    tracked_hosts = tracked_hosts + 1
    local host_policy = state.hostPolicies[host]
    local meta = build_refresh_meta(host, now_epoch)
    if meta.nextCheckEpoch <= now_epoch then
      due_now = due_now + 1
      local queued = false
      if state.autoDns.enabled == true then
        local requested_at_epoch = iso_to_epoch(meta.refreshRequestedAt)
        local can_queue = requested_at_epoch == nil or (now_epoch - requested_at_epoch) >= min_interval
        if can_queue then
          local current_meta = state.refreshMeta[host] or {}
          current_meta.refreshRequestedAt = now_iso_value
          current_meta.lastRequestedReason = reason
          current_meta.requestCount = (tonumber(current_meta.requestCount) or 0) + 1
          local current_next_epoch = iso_to_epoch(current_meta.nextCheckAt)
          if current_next_epoch == nil or current_next_epoch > now_epoch then
            current_meta.nextCheckAt = now_iso_value
          end
          state.refreshMeta[host] = current_meta
          if state.autoDns.requireChallenge == true then
            local issued_ref, issued_expires_at =
              issue_refresh_challenge(host, reason, state.autoDns.challengeTtlSec)
            current_meta = state.refreshMeta[host] or current_meta
            current_meta.pendingChallenge = issued_ref
            current_meta.challengeExpiresAt = issued_expires_at
            state.refreshMeta[host] = current_meta
          end
          queued = true
          queued_now = queued_now + 1
        end
      end
      table.insert(due, {
        host = host,
        siteId = host_policy and host_policy.siteId or nil,
        dnsProofState = meta.dnsProofState,
        nextCheckAt = meta.nextCheckAt,
        lastCheckAt = meta.lastCheckAt,
        retryCount = meta.retryCount,
        lastError = meta.lastError,
        refreshRequestedAt = state.refreshMeta[host] and state.refreshMeta[host].refreshRequestedAt or meta.refreshRequestedAt,
        lastRequestedReason = state.refreshMeta[host] and state.refreshMeta[host].lastRequestedReason or meta.lastRequestedReason,
        requestCount = state.refreshMeta[host] and tonumber(state.refreshMeta[host].requestCount or 0) or meta.requestCount,
        challengeRef = state.refreshMeta[host] and state.refreshMeta[host].pendingChallenge or meta.pendingChallenge,
        challengeExpiresAt = state.refreshMeta[host] and state.refreshMeta[host].challengeExpiresAt
          or meta.challengeExpiresAt,
        queued = queued,
      })
    end
  end

  table.sort(due, function(a, b)
    local left_epoch = iso_to_epoch(a.nextCheckAt) or 0
    local right_epoch = iso_to_epoch(b.nextCheckAt) or 0
    if left_epoch == right_epoch then
      return (a.host or "") < (b.host or "")
    end
    return left_epoch < right_epoch
  end)

  if #due > limit then
    local limited = {}
    for i = 1, limit do
      limited[i] = due[i]
    end
    due = limited
  end

  return codec.ok {
    schemaVersion = "1.0",
    generatedAt = now_iso(),
    nowEpoch = now_epoch,
    runReason = reason,
    limit = limit,
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    relayPlan = {
      mode = "hb_native",
      fetchOrder = { "cache", "relay" },
      txtRecordTemplate = "_darkmesh.%s",
      expectedTxtVersion = "dm1",
      applyAction = "ApplyDnsRefreshResult",
      challenge = {
        required = state.autoDns.requireChallenge == true,
        issueAction = "IssueDnsRefreshChallenge",
        ttlSec = state.autoDns.challengeTtlSec,
      },
    },
    counts = {
      trackedHosts = tracked_hosts,
      dueNow = due_now,
      queuedNow = queued_now,
      returned = #due,
    },
    dueHosts = due,
  }
end

function handlers.ApplyDnsRefreshResult(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Dns-Proof-State",
    "DnsProofState",
    "Dns-Proof-Valid-Until",
    "DnsProofValidUntil",
    "Dns-Proof-Source",
    "DnsProofSource",
    "Dns-Proof-Seq",
    "DnsProofSeq",
    "Site-Id",
    "SiteId",
    "Process-Id",
    "ProcessId",
    "Module-Id",
    "ModuleId",
    "Scheduler-Id",
    "SchedulerId",
    "Route-Prefix",
    "RoutePrefix",
    "Status",
    "Action-Hint",
    "ActionHint",
    "Challenge-Ref",
    "ChallengeRef",
    "Checked-At",
    "CheckedAt",
    "Next-Check-At",
    "NextCheckAt",
    "Retry-Count",
    "RetryCount",
    "Error",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local proof_state = normalize_proof_state(msg["Dns-Proof-State"] or msg.DnsProofState)
  local last_error = msg.Error ~= nil and trim(tostring(msg.Error)) or nil
  if last_error == "" then
    last_error = nil
  end
  if proof_state == nil and last_error == nil then
    return codec.error(
      "INVALID_INPUT",
      "missing_field:Dns-Proof-State-or-Error",
      { field = "Dns-Proof-State" }
    )
  end

  local checked_at = msg["Checked-At"] or msg.CheckedAt or now_iso()
  if type(checked_at) ~= "string" or iso_to_epoch(checked_at) == nil then
    return codec.error("INVALID_INPUT", "invalid_format:Checked-At", { field = "Checked-At" })
  end

  local valid_until = msg["Dns-Proof-Valid-Until"] or msg.DnsProofValidUntil
  if valid_until ~= nil then
    valid_until = tostring(valid_until)
    if iso_to_epoch(valid_until) == nil then
      return codec.error(
        "INVALID_INPUT",
        "invalid_format:Dns-Proof-Valid-Until",
        { field = "Dns-Proof-Valid-Until" }
      )
    end
  end

  local next_check_at = msg["Next-Check-At"] or msg.NextCheckAt
  if next_check_at ~= nil then
    next_check_at = tostring(next_check_at)
    if iso_to_epoch(next_check_at) == nil then
      return codec.error("INVALID_INPUT", "invalid_format:Next-Check-At", { field = "Next-Check-At" })
    end
  end

  local retry_count = nil
  if msg["Retry-Count"] ~= nil or msg.RetryCount ~= nil then
    local retry_err
    retry_count, retry_err = parse_int_field(msg["Retry-Count"] or msg.RetryCount, "Retry-Count", 0, 1000)
    if retry_err then
      return codec.error("INVALID_INPUT", retry_err, { field = "Retry-Count" })
    end
  end

  local proof_source = msg["Dns-Proof-Source"] or msg.DnsProofSource
  if proof_source ~= nil then
    proof_source = trim(tostring(proof_source)) or ""
    local ok_source_len, source_len_err = validation.check_length(proof_source, 128, "Dns-Proof-Source")
    if not ok_source_len or proof_source == "" then
      return codec.error("INVALID_INPUT", source_len_err or "invalid_format:Dns-Proof-Source", { field = "Dns-Proof-Source" })
    end
  end

  local challenge_ref, challenge_ref_err =
    normalize_challenge_ref(msg["Challenge-Ref"] or msg.ChallengeRef, "Challenge-Ref")
  if challenge_ref_err then
    return codec.error("INVALID_INPUT", challenge_ref_err, { field = "Challenge-Ref" })
  end

  local proof_sequence = nil
  if msg["Dns-Proof-Seq"] ~= nil or msg.DnsProofSeq ~= nil then
    local parsed_sequence, parsed_sequence_err =
      parse_int_field(msg["Dns-Proof-Seq"] or msg.DnsProofSeq, "Dns-Proof-Seq", 0, 2147483647)
    if parsed_sequence_err then
      return codec.error("INVALID_INPUT", parsed_sequence_err, { field = "Dns-Proof-Seq" })
    end
    proof_sequence = parsed_sequence
  end

  local now_epoch = os.time()
  local challenge_ok, challenge_err = validate_refresh_challenge(host, challenge_ref, now_epoch)
  if not challenge_ok then
    return codec.error("INVALID_INPUT", challenge_err, {
      field = "Challenge-Ref",
      challengeRequired = state.autoDns.requireChallenge == true,
    })
  end

  local existing_proof = state.dnsProofState[host] or {}
  local existing_sequence = tonumber(existing_proof.sequence)
  if proof_sequence ~= nil and existing_sequence ~= nil and proof_sequence < existing_sequence then
    return codec.error("INVALID_INPUT", "stale_sequence:Dns-Proof-Seq", {
      field = "Dns-Proof-Seq",
      existing = existing_sequence,
      received = proof_sequence,
    })
  end

  if proof_state ~= nil then
    state.dnsProofState[host] = {
      state = proof_state,
      checkedAt = checked_at,
      validUntil = valid_until,
      source = proof_source or "autonomous-refresh",
      challengeRef = challenge_ref,
      sequence = proof_sequence ~= nil and proof_sequence or existing_sequence,
    }
  end

  local applied_mapping = nil
  if proof_state == "valid" and last_error == nil then
    local mapped, map_err, map_field = upsert_host_policy_from_proof(host, msg)
    if map_err then
      return codec.error("INVALID_INPUT", map_err, { field = map_field or "Process-Id" })
    end
    applied_mapping = mapped
  end

  local existing_meta = state.refreshMeta[host] or {}
  local retry_value = retry_count
  if retry_value == nil then
    if last_error then
      retry_value = (tonumber(existing_meta.retryCount) or 0) + 1
    else
      retry_value = 0
    end
  end

  local computed_next_check = next_check_at
  if computed_next_check == nil then
    if valid_until ~= nil then
      computed_next_check = valid_until
    else
      computed_next_check = plus_seconds_iso(state.autoDns.refreshIntervalSec)
    end
  end

  state.refreshMeta[host] = {
    nextCheckAt = computed_next_check,
    lastCheckAt = checked_at,
    lastError = last_error,
    retryCount = retry_value,
    refreshRequestedAt = nil,
    lastRequestedReason = nil,
    requestCount = tonumber(existing_meta.requestCount) or 0,
  }
  clear_refresh_challenge(host)

  local removed = invalidate_cache_by_host(host)
  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    host = host,
    applied = true,
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
    dnsProofState = state.dnsProofState[host],
    refreshMeta = state.refreshMeta[host],
    hostPolicy = state.hostPolicies[host],
    sitePolicy = state.hostPolicies[host] and state.sitePolicies[state.hostPolicies[host].siteId] or nil,
    mapping = {
      applied = applied_mapping ~= nil,
      value = applied_mapping,
    },
  }
end

function handlers.ApplyHostPolicyFromProof(msg)
  if not ALLOW_DIRECT_HOST_POLICY_APPLY then
    return codec.error(
      "FORBIDDEN",
      "direct_host_policy_apply_disabled",
      { hint = "Use DNS TXT + AR config flow via ApplyDnsRefreshResult." }
    )
  end

  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Site-Id",
    "SiteId",
    "Process-Id",
    "ProcessId",
    "Module-Id",
    "ModuleId",
    "Scheduler-Id",
    "SchedulerId",
    "Route-Prefix",
    "RoutePrefix",
    "Status",
    "Action-Hint",
    "ActionHint",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host", "Process-Id" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local mapped, map_err, map_field = upsert_host_policy_from_proof(host, msg)
  if map_err then
    return codec.error("INVALID_INPUT", map_err, { field = map_field or "Process-Id" })
  end

  local removed = invalidate_cache_by_host(host)
  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    applied = true,
    host = host,
    mapping = mapped,
    hostPolicy = state.hostPolicies[host],
    sitePolicy = state.hostPolicies[host] and state.sitePolicies[state.hostPolicies[host].siteId] or nil,
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
  }
end

function handlers.ForceDnsRefreshHost(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Reason",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local reason = trim(tostring(msg.Reason or "manual_force")) or "manual_force"
  local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
  if not ok_reason_len or reason == "" then
    return codec.error("INVALID_INPUT", reason_len_err or "invalid_format:Reason", { field = "Reason" })
  end

  local now_value = now_iso()
  local meta = state.refreshMeta[host] or {}
  meta.nextCheckAt = now_value
  meta.refreshRequestedAt = now_value
  meta.lastRequestedReason = reason
  meta.requestCount = (tonumber(meta.requestCount) or 0) + 1
  state.refreshMeta[host] = meta
  if state.autoDns.requireChallenge == true then
    local issued_ref, issued_expires_at = issue_refresh_challenge(host, reason, state.autoDns.challengeTtlSec)
    meta = state.refreshMeta[host] or meta
    meta.pendingChallenge = issued_ref
    meta.challengeExpiresAt = issued_expires_at
    state.refreshMeta[host] = meta
  end

  local removed = invalidate_cache_by_host(host)
  state.cacheMeta.lastInvalidatedAt = now_iso()

  return codec.ok {
    schemaVersion = "1.0",
    forced = true,
    host = host,
    reason = reason,
    refreshMeta = state.refreshMeta[host],
    challenge = {
      required = state.autoDns.requireChallenge == true,
      challengeRef = state.refreshMeta[host] and state.refreshMeta[host].pendingChallenge or nil,
      challengeExpiresAt = state.refreshMeta[host] and state.refreshMeta[host].challengeExpiresAt or nil,
    },
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
  }
end

function handlers.IssueDnsRefreshChallenge(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Reason",
    "Challenge-Ttl-Sec",
    "ChallengeTtlSec",
    "Challenge-Ref",
    "ChallengeRef",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local reason = trim(tostring(msg.Reason or "manual_issue")) or "manual_issue"
  local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
  if not ok_reason_len or reason == "" then
    return codec.error("INVALID_INPUT", reason_len_err or "invalid_format:Reason", { field = "Reason" })
  end

  local ttl = state.autoDns.challengeTtlSec
  if msg["Challenge-Ttl-Sec"] ~= nil or msg.ChallengeTtlSec ~= nil then
    local parsed_ttl, parsed_ttl_err = parse_int_field(
      msg["Challenge-Ttl-Sec"] or msg.ChallengeTtlSec,
      "Challenge-Ttl-Sec",
      30,
      7200
    )
    if parsed_ttl_err then
      return codec.error("INVALID_INPUT", parsed_ttl_err, { field = "Challenge-Ttl-Sec" })
    end
    ttl = parsed_ttl
  end

  local explicit_ref, explicit_ref_err =
    normalize_challenge_ref(msg["Challenge-Ref"] or msg.ChallengeRef, "Challenge-Ref")
  if explicit_ref_err then
    return codec.error("INVALID_INPUT", explicit_ref_err, { field = "Challenge-Ref" })
  end

  local challenge_ref, challenge_expires_at, challenge_ttl = issue_refresh_challenge(host, reason, ttl, explicit_ref)
  return codec.ok {
    schemaVersion = "1.0",
    host = host,
    challenge = {
      required = state.autoDns.requireChallenge == true,
      challengeRef = challenge_ref,
      challengeExpiresAt = challenge_expires_at,
      challengeTtlSec = challenge_ttl,
      reason = reason,
    },
    refreshMeta = state.refreshMeta[host],
  }
end

function handlers.SetAdmissionRule(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Rule",
    "Reason",
    "Allowlist-Enabled",
    "AllowlistEnabled",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host", "Rule" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local rule = string.lower(trim(tostring(msg.Rule)) or "")
  if rule ~= "deny" and rule ~= "allow" then
    return codec.error("INVALID_INPUT", "invalid_format:Rule", { field = "Rule", allowed = { "deny", "allow" } })
  end

  local reason = trim(tostring(msg.Reason or "")) or ""
  if reason ~= "" then
    local ok_reason_len, reason_len_err = validation.check_length(reason, 128, "Reason")
    if not ok_reason_len then
      return codec.error("INVALID_INPUT", reason_len_err, { field = "Reason" })
    end
  end

  local allowlist_enabled = msg["Allowlist-Enabled"]
  if allowlist_enabled == nil then
    allowlist_enabled = msg.AllowlistEnabled
  end
  local previous_allowlist_enabled = state.admission.allowlistEnabled == true
  local allowlist_changed = false
  if allowlist_enabled ~= nil then
    local parsed_allowlist, parsed_allowlist_err =
      parse_boolean_field(allowlist_enabled, "Allowlist-Enabled", state.admission.allowlistEnabled == true)
    if parsed_allowlist_err then
      return codec.error("INVALID_INPUT", parsed_allowlist_err, { field = "Allowlist-Enabled" })
    end
    state.admission.allowlistEnabled = parsed_allowlist
    allowlist_changed = previous_allowlist_enabled ~= parsed_allowlist
  end

  local now_value = now_iso()
  if rule == "deny" then
    state.admission.denyHosts[host] = {
      reason = reason ~= "" and reason or "DENY_ADMISSION_BLOCKLIST",
      updatedAt = now_value,
    }
    state.admission.allowHosts[host] = nil
  else
    state.admission.allowHosts[host] = {
      reason = reason ~= "" and reason or "ALLOW_ADMISSION_ALLOWLIST",
      updatedAt = now_value,
    }
    state.admission.denyHosts[host] = nil
  end
  state.admission.updatedAt = now_value

  local removed = invalidate_cache_by_host(host)
  if allowlist_changed then
    removed = removed + invalidate_cache_all()
  end
  state.cacheMeta.lastInvalidatedAt = now_value

  return codec.ok {
    schemaVersion = "1.0",
    updated = true,
    host = host,
    rule = rule,
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      allowCount = map_count(state.admission.allowHosts),
      denyCount = map_count(state.admission.denyHosts),
      updatedAt = state.admission.updatedAt,
    },
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
  }
end

function handlers.RemoveAdmissionRule(msg)
  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Rule",
    "Allowlist-Enabled",
    "AllowlistEnabled",
    "Actor-Role",
    "Schema-Version",
    "Signature",
    "Hmac",
    "hmac",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local ok_fields, missing = validation.require_fields(msg, { "Host" })
  if not ok_fields then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local rule = string.lower(trim(tostring(msg.Rule or "both")) or "both")
  if rule ~= "deny" and rule ~= "allow" and rule ~= "both" then
    return codec.error("INVALID_INPUT", "invalid_format:Rule", { field = "Rule", allowed = { "deny", "allow", "both" } })
  end

  if rule == "deny" or rule == "both" then
    state.admission.denyHosts[host] = nil
  end
  if rule == "allow" or rule == "both" then
    state.admission.allowHosts[host] = nil
  end

  local allowlist_enabled = msg["Allowlist-Enabled"]
  if allowlist_enabled == nil then
    allowlist_enabled = msg.AllowlistEnabled
  end
  local previous_allowlist_enabled = state.admission.allowlistEnabled == true
  local allowlist_changed = false
  if allowlist_enabled ~= nil then
    local parsed_allowlist, parsed_allowlist_err =
      parse_boolean_field(allowlist_enabled, "Allowlist-Enabled", state.admission.allowlistEnabled == true)
    if parsed_allowlist_err then
      return codec.error("INVALID_INPUT", parsed_allowlist_err, { field = "Allowlist-Enabled" })
    end
    state.admission.allowlistEnabled = parsed_allowlist
    allowlist_changed = previous_allowlist_enabled ~= parsed_allowlist
  end

  state.admission.updatedAt = now_iso()
  local removed = invalidate_cache_by_host(host)
  if allowlist_changed then
    removed = removed + invalidate_cache_all()
  end
  state.cacheMeta.lastInvalidatedAt = state.admission.updatedAt

  return codec.ok {
    schemaVersion = "1.0",
    removed = true,
    host = host,
    rule = rule,
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      allowCount = map_count(state.admission.allowHosts),
      denyCount = map_count(state.admission.denyHosts),
      updatedAt = state.admission.updatedAt,
    },
    cacheInvalidation = {
      scope = "host",
      removedEntries = removed,
      lastInvalidatedAt = state.cacheMeta.lastInvalidatedAt,
    },
  }
end

function handlers.GetAdmissionState(_msg)
  return codec.ok {
    schemaVersion = "1.0",
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      allowHosts = state.admission.allowHosts,
      denyHosts = state.admission.denyHosts,
      allowCount = map_count(state.admission.allowHosts),
      denyCount = map_count(state.admission.denyHosts),
      updatedAt = state.admission.updatedAt,
    },
  }
end

function handlers.ResolveRouteForHost(msg)
  local ok, missing = validation.require_fields(msg, { "Host", "Path", "Method" })
  if not ok then
    return codec.error("INVALID_INPUT", "Missing field", { missing = missing })
  end

  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "Path",
    "Method",
    "Node-Id",
    "nodeId",
    "Resolver-Id",
    "Policy-Mode",
    "PolicyMode",
    "Schema-Version",
    "Query",
    "Actor-Role",
    "X-Caller",
    "Site-Id",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local host, host_err = normalize_host(msg.Host, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end
  local path, path_err = normalize_path(msg.Path, "Path")
  if not path then
    return codec.error("INVALID_INPUT", path_err, { field = "Path" })
  end
  local method, method_err = normalize_method(msg.Method, "Method")
  if not method then
    return codec.error("INVALID_INPUT", method_err, { field = "Method" })
  end

  local node_id, node_err = parse_node_id(msg)
  if node_err then
    return codec.error("INVALID_INPUT", node_err, { field = "Node-Id" })
  end

  local admission_decision, admission_reason = evaluate_admission(host)
  if admission_decision == "deny" then
    local request_id = read_request_id(msg)
    local payload = {
      schemaVersion = "1.0",
      requestId = request_id,
      decision = "deny",
      reasonCode = admission_reason,
      mode = normalize_mode(msg["Policy-Mode"] or msg.PolicyMode),
      host = host,
      path = path,
      method = method,
      nodeId = node_id,
      routeHint = {
        actionHint = infer_action_hint(path, method),
        source = "inferred",
      },
      cache = build_cache_payload(false, build_proof_payload(host), "route", "miss"),
      proof = build_proof_payload(host),
      admission = {
        decision = admission_decision,
        reasonCode = admission_reason,
      },
    }
    return codec.ok(with_result_envelope(payload))
  end

  local requested_mode = msg["Policy-Mode"] or msg.PolicyMode
  local mode, mode_fallback_reason = normalize_mode(requested_mode)
  local request_id = read_request_id(msg)
  local cache_key = make_cache_key("route", host, path, method, mode)
  local cached_entry, cache_state = get_cached_resolution(cache_key)
  if cached_entry then
    local cached_refresh = maybe_queue_refresh_from_access(
      host,
      cached_entry.proof,
      cached_entry.hostKnown == true,
      cache_state
    )
    return codec.ok(payload_from_cached_entry(cached_entry, request_id, node_id, cache_state, cached_refresh))
  end

  local host_policy = state.hostPolicies[host]
  local host_known = host_policy ~= nil
  local proof_payload = build_proof_payload(host)
  local decision, reason_code = evaluate_route_decision(mode, host_known, proof_payload.dnsProofState)
  if mode_fallback_reason then
    reason_code = mode_fallback_reason
  end

  local site_obj, process_obj = infer_site_process(host, host_policy)
  local action_hint, hint_source = resolve_action_hint(host, path, method, host_policy)
  local execution_flow_hint = build_execution_flow_hint(process_obj)
  state.lastResolvedAt = now_iso()

  local payload = {
    schemaVersion = "1.0",
    requestId = request_id,
    decision = decision,
    reasonCode = reason_code,
    mode = mode,
    host = host,
    path = path,
    method = method,
    nodeId = node_id,
    routeHint = {
      actionHint = action_hint,
      source = hint_source,
      executionFlow = execution_flow_hint,
    },
    cache = build_cache_payload(host_known, proof_payload, "route", "miss"),
    proof = proof_payload,
  }

  if site_obj then
    payload.site = site_obj
  end
  if process_obj then
    payload.process = process_obj
  end
  local refresh_payload = maybe_queue_refresh_from_access(host, proof_payload, host_known, "miss")
  if refresh_payload ~= nil then
    payload.refresh = refresh_payload
  end

  upsert_resolution_cache(cache_key, host, {
    siteId = site_obj and site_obj.siteId or nil,
    decision = payload.decision,
    reasonCode = payload.reasonCode,
    mode = payload.mode,
    proofState = proof_payload.dnsProofState,
    dnsNextCheckAt = payload.cache.dnsNextCheckAt,
    surface = "route",
    actionHint = payload.routeHint.actionHint,
    hostKnown = host_known,
    path = path,
    method = method,
    process = process_obj,
    site = site_obj,
    proof = proof_payload,
    executionFlow = execution_flow_hint,
  })
  return codec.ok(with_result_envelope(payload))
end

function handlers.ResolveHostForNode(msg)
  local host_input = msg.Host or msg.host
  if host_input == nil then
    return codec.error("INVALID_INPUT", "Missing field", { missing = { "Host" } })
  end

  local ok_extra, extras = validation.require_no_extras(msg, {
    "Action",
    "Request-Id",
    "Host",
    "host",
    "Node-Id",
    "nodeId",
    "Resolver-Id",
    "Policy-Mode",
    "PolicyMode",
    "Schema-Version",
    "Method",
    "Path",
    "Query",
    "Actor-Role",
    "X-Caller",
    "Site-Id",
    "Signature",
  })
  if not ok_extra then
    return codec.error("UNSUPPORTED_FIELD", "Unexpected fields", { unexpected = extras })
  end

  local host, host_err = normalize_host(host_input, "Host")
  if not host then
    return codec.error("INVALID_INPUT", host_err, { field = "Host" })
  end

  local node_id, node_err = parse_node_id(msg)
  if node_err then
    return codec.error("INVALID_INPUT", node_err, { field = "Node-Id" })
  end

  local admission_decision, admission_reason = evaluate_admission(host)
  if admission_decision == "deny" then
    local request_id = read_request_id(msg)
    local payload = {
      schemaVersion = "1.0",
      requestId = request_id,
      decision = "deny",
      reasonCode = admission_reason,
      mode = normalize_mode(msg["Policy-Mode"] or msg.PolicyMode),
      host = host,
      nodeId = node_id,
      cache = build_cache_payload(false, build_proof_payload(host), "host", "miss"),
      proof = build_proof_payload(host),
      admission = {
        decision = admission_decision,
        reasonCode = admission_reason,
      },
    }
    return codec.ok(with_result_envelope(payload))
  end

  local requested_mode = msg["Policy-Mode"] or msg.PolicyMode
  local mode, mode_fallback_reason = normalize_mode(requested_mode)
  local request_id = read_request_id(msg)
  local cache_key = make_cache_key("host", host, nil, nil, mode)
  local cached_entry, cache_state = get_cached_resolution(cache_key)
  if cached_entry then
    local cached_refresh = maybe_queue_refresh_from_access(
      host,
      cached_entry.proof,
      cached_entry.hostKnown == true,
      cache_state
    )
    return codec.ok(payload_from_cached_entry(cached_entry, request_id, node_id, cache_state, cached_refresh))
  end

  local host_policy = state.hostPolicies[host]
  local host_known = host_policy ~= nil
  local site_obj, process_obj = infer_site_process(host, host_policy)
  local execution_flow_hint = build_execution_flow_hint(process_obj)
  local proof_payload = build_proof_payload(host)
  local decision, reason_code = evaluate_host_decision(mode, host_known, proof_payload.dnsProofState)
  if mode_fallback_reason then
    reason_code = mode_fallback_reason
  end

  state.lastResolvedAt = now_iso()

  local payload = {
    schemaVersion = "1.0",
    requestId = request_id,
    decision = decision,
    reasonCode = reason_code,
    mode = mode,
    host = host,
    nodeId = node_id,
    cache = build_cache_payload(host_known, proof_payload, "host", "miss"),
    proof = proof_payload,
    executionFlow = execution_flow_hint,
  }

  if site_obj then
    payload.site = site_obj
  end
  if process_obj then
    payload.process = process_obj
  end
  local refresh_payload = maybe_queue_refresh_from_access(host, proof_payload, host_known, "miss")
  if refresh_payload ~= nil then
    payload.refresh = refresh_payload
  end

  upsert_resolution_cache(cache_key, host, {
    siteId = site_obj and site_obj.siteId or nil,
    decision = payload.decision,
    reasonCode = payload.reasonCode,
    mode = payload.mode,
    proofState = proof_payload.dnsProofState,
    dnsNextCheckAt = payload.cache.dnsNextCheckAt,
    surface = "host",
    actionHint = nil,
    hostKnown = host_known,
    path = nil,
    method = nil,
    process = process_obj,
    site = site_obj,
    proof = proof_payload,
    executionFlow = execution_flow_hint,
  })

  return codec.ok(with_result_envelope(payload))
end

map_count = function(tbl)
  local count = 0
  for _ in pairs(tbl or {}) do
    count = count + 1
  end
  return count
end

function handlers.GetResolverState(_msg)
  ensure_cache_hints()
  local pending_challenges = 0
  for _, meta in pairs(state.refreshMeta or {}) do
    if meta and type(meta.pendingChallenge) == "string" and meta.pendingChallenge ~= "" then
      pending_challenges = pending_challenges + 1
    end
  end
  return codec.ok {
    schemaVersion = "1.0",
    policyMode = normalize_mode(state.policyMode),
    failOpen = state.failOpen ~= false,
    cacheHints = {
      positiveTtlSec = state.cacheHints.positiveTtlSec,
      negativeTtlSec = state.cacheHints.negativeTtlSec,
      staleWhileRevalidateSec = state.cacheHints.staleWhileRevalidateSec,
      hardMaxStaleSec = state.cacheHints.hardMaxStaleSec,
    },
    autoDns = {
      enabled = state.autoDns.enabled == true,
      refreshOnStale = state.autoDns.refreshOnStale == true,
      refreshIntervalSec = state.autoDns.refreshIntervalSec,
      staleRefreshMinIntervalSec = state.autoDns.staleRefreshMinIntervalSec,
      maxHostsPerRun = state.autoDns.maxHostsPerRun,
      staleGraceSec = state.autoDns.staleGraceSec,
      requireChallenge = state.autoDns.requireChallenge == true,
      challengeTtlSec = state.autoDns.challengeTtlSec,
      paths = refresh_paths_snapshot(),
      endpoints = refresh_endpoints_snapshot(),
    },
    executionFlow = execution_flow_snapshot(),
    counts = {
      hostPolicies = map_count(state.hostPolicies),
      sitePolicies = map_count(state.sitePolicies),
      routePolicies = map_count(state.routePolicies),
      dnsProofState = map_count(state.dnsProofState),
      refreshMeta = map_count(state.refreshMeta),
      refreshChallengesPending = pending_challenges,
      resolutionCache = map_count(state.resolutionCache),
      admissionAllow = map_count(state.admission and state.admission.allowHosts or {}),
      admissionDeny = map_count(state.admission and state.admission.denyHosts or {}),
    },
    admission = {
      allowlistEnabled = state.admission.allowlistEnabled == true,
      updatedAt = state.admission.updatedAt,
    },
    bundleMeta = state.bundleMeta,
    cacheMeta = state.cacheMeta,
    lastResolvedAt = state.lastResolvedAt,
    debugLevel = "safe",
  }
end

local function route(msg)
  local ok, missing = validation.require_tags(msg, { "Action" })
  if not ok then
    return codec.missing_tags(missing)
  end

  local ok_action, err = validation.require_action(msg, allowed_actions)
  if not ok_action then
    if err == "unknown_action" then
      return codec.unknown_action(msg.Action)
    end
    return codec.error("MISSING_ACTION", "Action is required")
  end

  prune_resolution_cache()
  prune_refresh_meta()

  local requires_auth = PUBLIC_READ_REQUIRE_AUTH or not public_read_actions[msg.Action]
  if requires_auth then
    local ok_sec, sec_err = auth.enforce(msg)
    if not ok_sec then
      return codec.error("FORBIDDEN", sec_err)
    end
  else
    local ok_rl, rl_err = auth.check_rate_limit(msg)
    if not ok_rl then
      return codec.error("FORBIDDEN", rl_err)
    end
  end

  local ok_hmac, hmac_err =
    auth.verify_outbox_hmac_for_action(msg, { skip_for = hmac_skip_actions })
  if not ok_hmac then
    return codec.error("FORBIDDEN", hmac_err)
  end

  local ok_role, role_err = auth.require_role_for_action(msg, role_policy)
  if not ok_role then
    return codec.error("FORBIDDEN", role_err)
  end

  -- Auth/transport metadata is needed for enforcement, but handlers should not
  -- have to whitelist it explicitly in every require_no_extras() contract.
  local handler_msg = sanitize_handler_message(msg)

  local request_id = read_request_id(handler_msg)
  local scope_host = tostring(handler_msg.Host or handler_msg.host or "")
  local scope_path = tostring(handler_msg.Path or handler_msg.path or "")
  local scope_method = string.upper(tostring(handler_msg.Method or handler_msg.method or ""))
  local idem_key = nil
  if request_id ~= "" then
    idem_key =
      table.concat({ request_id, tostring(handler_msg.Action), scope_host, scope_path, scope_method }, "|")
    local seen = idem.check(idem_key)
    if seen then
      return seen
    end
  end

  local handler = handlers[handler_msg.Action]
  if not handler then
    return codec.unknown_action(handler_msg.Action)
  end

  refresh_state_mutated = false
  local previous_refresh_mutation_flag = request_allows_refresh_queue_mutation
  request_allows_refresh_queue_mutation = requires_auth or ALLOW_PUBLIC_READ_REFRESH_QUEUE
  local resp = handler(handler_msg)
  request_allows_refresh_queue_mutation = previous_refresh_mutation_flag
  metrics.inc("resolver." .. handler_msg.Action .. ".count")
  metrics.tick()
  if idem_key ~= nil then
    idem.record(idem_key, resp)
  end
  maybe_persist_state(mutating_actions[handler_msg.Action] == true or refresh_state_mutated)
  return resp
end

local cjson_ok, cjson = pcall(require, "cjson.safe")

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local i = 0
  for _ in pairs(value) do
    i = i + 1
    if value[i] == nil then
      return false
    end
  end
  return true
end

local function fallback_json_encode(value)
  local value_type = type(value)
  if value_type == "nil" then
    return "null"
  end
  if value_type == "boolean" then
    return value and "true" or "false"
  end
  if value_type == "number" then
    return tostring(value)
  end
  if value_type == "string" then
    return string.format("%q", value)
  end
  if value_type == "table" then
    if is_array(value) then
      local parts = {}
      for _, item in ipairs(value) do
        parts[#parts + 1] = fallback_json_encode(item)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for key, item in pairs(value) do
      parts[#parts + 1] = string.format("%q:%s", tostring(key), fallback_json_encode(item))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return '"<unsupported>"'
end

local function encode_json(value)
  if cjson_ok and type(cjson) == "table" and type(cjson.encode) == "function" then
    local ok_encoded, encoded = pcall(cjson.encode, value)
    if ok_encoded and type(encoded) == "string" then
      return encoded
    end
  end
  return fallback_json_encode(value)
end

local function emit_response_json(json_text)
  local bridge = type(_G) == "table" and _G.__dm_emit_output or nil
  if type(bridge) == "function" then
    local ok_bridge, bridge_result = pcall(bridge, json_text)
    if ok_bridge and type(bridge_result) == "string" then
      return bridge_result
    end
  end
  pcall(function()
    if type(print) == "function" then
      print(json_text)
    end
  end)
  return json_text
end

local function resolve_reply_target(msg, tags)
  local target =
    msg.From or
    msg.from or
    msg["Reply-To"] or
    msg["ReplyTo"] or
    msg.replyTo or
    tag_value(tags, "Reply-To") or
    tag_value(tags, "ReplyTo")
  if type(target) == "string" and target ~= "" then
    return target
  end
  return nil
end

local function safe_send(payload)
  if type(Send) ~= "function" then
    return false
  end
  local ok = pcall(function()
    Send(payload)
  end)
  return ok
end

local function structured_output_result(json_text)
  if type(ao) == "table" and type(ao.result) == "function" then
    return ao.result({
      Output = {
        data = json_text,
        prompt = type(Prompt) == "function" and Prompt() or nil,
        print = true,
      },
      Messages = {},
      Spawns = {},
      Assignments = {},
    })
  end
  return json_text
end

local function trace_resolver_route(label, msg)
  if type(_G) ~= "table" or not _G.__dm_trace_resolver_route then
    return
  end
  local action = nil
  pcall(function()
    local normalized = enrich_message(msg or {})
    action = normalized.Action
  end)
  local line = "__DM_TRACE_RESOLVER_ROUTE__ " .. tostring(label) .. " action=" .. tostring(action)
  pcall(function()
    if type(io) == "table" and type(io.stderr) == "table" and type(io.stderr.write) == "function" then
      io.stderr:write(line .. "\n")
    end
  end)
  pcall(function()
    if type(print) == "function" then
      print(line)
    end
  end)
end

local function tag_value(tags, name)
  if type(tags) ~= "table" then
    return nil
  end
  -- array-style tags: { { name = "...", value = "..." }, ... }
  for _, entry in ipairs(tags) do
    if type(entry) == "table" then
      local entry_name = entry.name or entry.Name
      if entry_name == name then
        local value = entry.value
        if value == nil then
          value = entry.Value
        end
        return value
      end
    end
  end
  -- map-style tags: { Action = "...", Host = "..." }
  if tags[name] ~= nil then
    return tags[name]
  end
  -- mixed/object-style tags: { ["Action"] = { value = "..." } }
  local boxed = tags[name]
  if type(boxed) == "table" then
    return boxed.value or boxed.Value
  end
  for key, value in pairs(tags) do
    if key == name then
      if type(value) == "table" then
        return value.value or value.Value
      end
      return value
    end
  end
  return nil
end

local function parse_json_object(raw)
  if type(raw) ~= "string" then
    return nil
  end
  local trimmed = trim(raw)
  if trimmed == nil or trimmed == "" then
    return nil
  end
  if not (trimmed:sub(1, 1) == "{" and trimmed:sub(-1) == "}") then
    return nil
  end
  if not (cjson_ok and type(cjson) == "table" and type(cjson.decode) == "function") then
    return nil
  end
  local ok_decoded, decoded = pcall(cjson.decode, trimmed)
  if ok_decoded and type(decoded) == "table" then
    return decoded
  end
  return nil
end

local function merge_string_keys(dst, src)
  if type(dst) ~= "table" or type(src) ~= "table" then
    return
  end
  for key, value in pairs(src) do
    if type(key) == "string" and dst[key] == nil then
      dst[key] = value
    end
  end
end

local function merge_tag_keys(dst, tags)
  if type(dst) ~= "table" or type(tags) ~= "table" then
    return
  end
  -- array-style tags: { { name = "...", value = "..." }, ... }
  for _, entry in ipairs(tags) do
    if type(entry) == "table" then
      local name = entry.name or entry.Name
      local value = entry.value or entry.Value
      if type(name) == "string" and dst[name] == nil and value ~= nil then
        dst[name] = value
      end
    end
  end
  -- map-style tags: { Action = "...", Host = "..." }
  for key, value in pairs(tags) do
    if type(key) == "string" and dst[key] == nil then
      if type(value) == "table" then
        local boxed = value.value or value.Value
        if boxed ~= nil then
          dst[key] = boxed
        end
      elseif value ~= nil then
        dst[key] = value
      end
    end
  end
end

local function url_decode_component(raw)
  if type(raw) ~= "string" then
    return raw
  end
  local replaced = raw:gsub("+", " ")
  return (replaced:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function parse_query_string(raw)
  if type(raw) ~= "string" then
    return {}
  end
  local query = trim(raw)
  if query == nil or query == "" then
    return {}
  end
  if query:sub(1, 1) == "?" then
    query = query:sub(2)
  end
  local out = {}
  for pair in query:gmatch("([^&]+)") do
    local key, value = pair:match("^([^=]+)=(.*)$")
    if key == nil then
      key = pair
      value = ""
    end
    key = url_decode_component(key or "")
    value = url_decode_component(value or "")
    if key ~= "" and out[key] == nil then
      out[key] = value
    end
  end
  return out
end

local function query_from_path(raw_path)
  if type(raw_path) ~= "string" then
    return {}
  end
  local query = raw_path:match("%?(.*)$")
  if not query then
    return {}
  end
  return parse_query_string(query)
end

local function merge_query_keys(dst, query)
  if type(dst) ~= "table" or type(query) ~= "table" then
    return
  end
  for key, value in pairs(query) do
    if type(key) == "string" and value ~= nil then
      if dst[key] == nil then
        dst[key] = value
      end
      local lower = string.lower(key)
      if lower == "action" and dst.Action == nil then
        dst.Action = value
      elseif lower == "host" and dst.Host == nil then
        dst.Host = value
      elseif lower == "path" and dst.Path == nil then
        dst.Path = value
      elseif lower == "method" and dst.Method == nil then
        dst.Method = value
      elseif lower == "request-id" and dst["Request-Id"] == nil then
        dst["Request-Id"] = value
      elseif lower == "node-id" and dst["Node-Id"] == nil then
        dst["Node-Id"] = value
      end
    end
  end
end

local function infer_action_from_http_path(path_like)
  if type(path_like) ~= "string" then
    return nil
  end
  local candidate = trim(path_like)
  if candidate == nil or candidate == "" then
    return nil
  end
  candidate = candidate:gsub("^https?://[^/]+", "")
  local base = candidate:match("^[^?]+") or candidate
  local action = base:match("/([A-Za-z][A-Za-z0-9_-]+)$")
  if type(action) == "string" and handlers[action] ~= nil then
    return action
  end
  return nil
end

local function enrich_message(msg)
  local envelope = (type(msg) == "table" and (msg.Body or msg.body)) or {}
  local tags = msg.Tags or msg.tags or envelope.Tags or envelope.tags or {}
  local data_obj = parse_json_object(msg.Data or msg.data)
    or parse_json_object(envelope.Data or envelope.data)
    or {}

  local out = {}
  merge_string_keys(out, data_obj)
  merge_string_keys(out, envelope)
  merge_string_keys(out, msg)
  merge_tag_keys(out, tags)
  merge_query_keys(out, parse_query_string(msg.Query or msg.query))
  merge_query_keys(out, parse_query_string(envelope.Query or envelope.query))
  merge_query_keys(out, parse_query_string(tag_value(tags, "Query") or tag_value(tags, "query")))

  local path_candidates = {
    out.Path,
    out.path,
    out.Uri,
    out.uri,
    out.URL,
    out.url,
    out["Request-Path"],
    out.request_path,
    msg.Path,
    msg.path,
    msg.Uri,
    msg.uri,
    msg.URL,
    msg.url,
  }
  for _, candidate in ipairs(path_candidates) do
    if type(candidate) == "string" and candidate ~= "" then
      merge_query_keys(out, query_from_path(candidate))
    end
  end

  out.Action = out.Action or out.action or tag_value(tags, "Action")
  if out.Action == nil then
    for _, candidate in ipairs(path_candidates) do
      local inferred = infer_action_from_http_path(candidate)
      if inferred ~= nil then
        out.Action = inferred
        break
      end
    end
  end
  out.Host = out.Host or out.host
  out.Path = out.Path or out.path
  out.Method = out.Method or out.method
  out["Request-Id"] = out["Request-Id"] or out.requestId or tag_value(tags, "Request-Id")
  out["Actor-Role"] = out["Actor-Role"] or out.actorRole or tag_value(tags, "Actor-Role")
  out["Schema-Version"] = out["Schema-Version"]
    or out.schemaVersion
    or tag_value(tags, "Schema-Version")
  out.Signature = out.Signature or out.signature or tag_value(tags, "Signature")
  out.Nonce = out.Nonce or out.nonce or tag_value(tags, "Nonce")
  out.ts = out.ts or out.timestamp or tag_value(tags, "ts")
  out.From = msg.From or msg.from
  out.Tags = tags
  return out
end

local function handle_resolver_action(msg)
  local normalized = enrich_message(msg or {})
  trace_resolver_route("handle_resolver_action", normalized)
  local ok_route, route_result = pcall(route, normalized)
  local resp = ok_route and route_result
    or codec.error("HANDLER_CRASH", tostring(route_result or "resolver_handler_crash"))
  local json_text = encode_json(resp)
  local reply_target = resolve_reply_target(msg or {}, normalized.Tags)
  if reply_target then
    safe_send {
      Target = reply_target,
      Action = "Resolver-Command-Result",
      ["Resolver-Action"] = normalized.Action,
      ["Request-Id"] = normalized["Request-Id"],
      ["Read-Contract-Version"] = "resolver-reply-message.v1",
      ["Content-Type"] = "application/json",
      Data = json_text,
    }
  end
  emit_response_json(json_text)
  return structured_output_result(json_text)
end

local function is_resolver_action(msg)
  if type(msg) ~= "table" then
    return false
  end
  local normalized = enrich_message(msg)
  local action = normalized.Action
  return type(action) == "string" and handlers[action] ~= nil
end

local resolver_handler_registered = false
local resolver_evaluate_wrapped = false
local original_handlers_evaluate = nil
local function resolve_handlers_api()
  if type(_G) == "table" and type(_G.Handlers) == "table" then
    return _G.Handlers
  end
  local env = _ENV
  if type(env) == "table" and type(env.Handlers) == "table" then
    return env.Handlers
  end
  return nil
end

local function ensure_resolver_evaluate_wrapped(handlers_api)
  local api = handlers_api
  if type(api) ~= "table" then
    api = resolve_handlers_api()
  end
  if type(api) ~= "table" or type(api.evaluate) ~= "function" then
    return false
  end
  if not resolver_evaluate_wrapped then
    original_handlers_evaluate = api.evaluate
    api.evaluate = function(msg, env)
      if is_resolver_action(msg) then
        trace_resolver_route("wrapped_evaluate", msg)
        return handle_resolver_action(msg)
      end
      return original_handlers_evaluate(msg, env)
    end
    resolver_evaluate_wrapped = true
  end
  return true
end

local function ensure_resolver_handler_registered()
  local handlers_api = resolve_handlers_api()
  if type(handlers_api) ~= "table" or type(handlers_api.add) ~= "function" then
    local ok_handlers, resolved_handlers = pcall(require, ".handlers")
    if
      ok_handlers
      and type(resolved_handlers) == "table"
      and type(resolved_handlers.add) == "function"
    then
      handlers_api = resolved_handlers
    else
      return false
    end
  end

  if not resolver_handler_registered then
    handlers_api.add("Resolver-Action", is_resolver_action, handle_resolver_action)
    resolver_handler_registered = true
  end
  ensure_resolver_evaluate_wrapped(handlers_api)
  return true
end

-- Default to eager wrapper registration so resolver actions are wired on
-- runtime profiles that invoke global Handle/handle or Handlers.handle paths.
-- Keep an explicit opt-out for lab experiments.
local eager_resolver_wrappers_enabled = true
if type(_G) == "table" and _G.__dm_disable_eager_resolver_wrappers == true then
  eager_resolver_wrappers_enabled = false
end

-- Late process.handle rebinding has proven replay-sensitive on the current
-- AO runtime path. Keep it opt-in for focused lab experiments only.
local eager_resolver_process_handle_wrap_enabled = false
if type(_G) == "table" and _G.__dm_enable_resolver_process_handle_wrap == true then
  eager_resolver_process_handle_wrap_enabled = true
end

local function fallback_handle(msg)
  ensure_resolver_handler_registered()
  trace_resolver_route("fallback_handle_pre", msg)
  if is_resolver_action(msg) then
    trace_resolver_route("fallback_handle", msg)
    return handle_resolver_action(msg)
  end
  return nil
end

if type(_G) == "table" then
  _G.__dm_bootstrap_resolver_evaluate_wrapper = function()
    local handlers_api = resolve_handlers_api()
    if type(handlers_api) ~= "table" or type(handlers_api.evaluate) ~= "function" then
      return false
    end
    return ensure_resolver_evaluate_wrapped(handlers_api)
  end
  _G.__dm_resolver_handle_action = function(msg)
    if not is_resolver_action(msg) then
      return nil
    end
    trace_resolver_route("external_handle_action", msg)
    return handle_resolver_action(msg)
  end
  _G.__dm_resolver_inline_route = function(msg)
    ensure_resolver_handler_registered()
    if is_resolver_action(msg) then
      trace_resolver_route("inline_route", msg)
      return handle_resolver_action(msg)
    end
    return nil
  end
end

local resolver_process_handle_wrapped = false
local original_process_handle = nil

local function ensure_resolver_process_handle_wrapped()
  if resolver_process_handle_wrapped then
    return true
  end
  if type(process) ~= "table" or type(process.handle) ~= "function" then
    return false
  end
  original_process_handle = process.handle
  process.handle = function(msg, env)
    local routed = fallback_handle(msg)
    if routed ~= nil then
      trace_resolver_route("process_handle_wrapper", msg)
      return routed
    end
    return original_process_handle(msg, env)
  end
  resolver_process_handle_wrapped = true
  return true
end

if eager_resolver_wrappers_enabled then
  ensure_resolver_handler_registered()
  if eager_resolver_process_handle_wrap_enabled then
    ensure_resolver_process_handle_wrapped()
  end
end

local previous_Handle = nil
local previous_handle = nil
if eager_resolver_wrappers_enabled then
  previous_Handle = _G.Handle
  previous_handle = _G.handle
end

local function emit_handler_error(code, message, meta)
  return emit_response_json(encode_json(codec.error(code, message, meta)))
end

local function merged_global_handle(original, msg)
  local routed = fallback_handle(msg)
  if routed ~= nil then
    return routed
  end
  if type(original) == "function" then
    local ok_original, original_result = pcall(original, msg)
    if ok_original then
      return original_result
    else
      return emit_handler_error(
        "HANDLER_CRASH",
        tostring(original_result or "resolver_original_handle_crash")
      )
    end
  end
  return nil
end

if eager_resolver_wrappers_enabled then
  _G.Handle = function(msg)
    return merged_global_handle(previous_Handle, msg)
  end

  _G.handle = function(msg)
    local original = previous_handle
    if type(original) ~= "function" then
      original = previous_Handle
    end
    return merged_global_handle(original, msg)
  end
end

-- Some runtime wrappers invoke `Handlers.handle(msg)` instead of global
-- `Handle/handle`. Keep this alias in sync so wasm-lua wrappers do not fail
-- with "attempt to call a nil value (field 'handle')".
local function ensure_handlers_handle_alias()
  -- Keep a hard fallback on the global namespace, because some wasm-lua
  -- wrappers call `Handlers.handle(msg)` directly even when `.handlers`
  -- is unavailable.
  if type(_G) == "table" then
    if type(_G.Handlers) ~= "table" then
      _G.Handlers = {}
    end
    -- Force bridge even when handle already exists; some runtimes bypass
    -- global Handle/handle and call Handlers.handle directly.
    _G.Handlers.handle = function(msg)
      return _G.handle(msg)
    end
  end

  local handlers_api = resolve_handlers_api()
  if type(handlers_api) ~= "table" then
    return
  end
  -- Same bridge on resolved handlers table so both namespaces stay in sync.
  handlers_api.handle = function(msg)
    return _G.handle(msg)
  end
end

if eager_resolver_wrappers_enabled then
  ensure_handlers_handle_alias()
end

return {
  route = route,
  _state = state,
}
]====], "ao.resolver.process")
  if not loaded then error(err) end
  local ret = loaded()
  if ret ~= nil then return ret end
end


if type(_G) == "table" then
  _G.__dm_emit_output = function(text)
    if type(print) == "function" then
      print(text)
    end
    return text
  end
end

local __ok_resolver, __err_resolver = pcall(require, "ao.resolver.process")
if not __ok_resolver then error(__err_resolver) end

return process
