local Class = require('hydra.class')
local hint = require('hydra.hint')
local options = require('hydra.options')
local util = require('hydra.util')
local termcodes = util.termcodes

local default_config = {
   debug = false,
   exit = false,
   foreign_keys = nil, -- nil | 'warn' | 'run'
   color = 'red',
   on_enter  = nil, -- before entering hydra
   on_exit = nil, -- after leaving hydra
   timeout = false, -- true, false or number in milliseconds
   invoke_on_body = false,
   buffer = nil,
   hint = { -- table | 'statusline' | false
      position = 'bottom',
      border = nil,
   }
}

---Currently active hydra
_G.Hydra = nil

---@class Hydra
---@field id number
---@field name string | nil
---@field hint HydraHint
---@field config table
---@field mode string | string[]
---@field body string
---@field heads table<string, string | function | table>
---@field options HydraOptions
---@field plug table<string, string>
---@field meta_accessors table
local Hydra = Class()

---@param input table
---@return Hydra
function Hydra:_constructor(input)
   do -- validate parameters
      vim.validate({
         name = { input.name, 'string', true },
         config = { input.config, 'table', true },
         mode = { input.mode, { 'string', 'table' }, true },
         body = { input.body, 'string', true },
         heads = { input.heads, 'table' },
      })
      if input.config then
         vim.validate({
            on_enter = { input.config.on_enter, 'function', true },
            on_exit = { input.config.on_exit, 'function', true },
            exit = { input.config.exit, 'boolean', true },
            timeout = { input.config.timeout, { 'boolean', 'number' }, true },
            buffer = { input.config.buffer, { 'boolean', 'number' }, true },
            hint = { input.config.hint, { 'boolean', 'string', 'table' }, true }
         })
         vim.validate({
            foreign_keys = { input.config.foreign_keys, function(foreign_keys)
               if type(foreign_keys) == 'nil'
                  or foreign_keys == 'warn' or foreign_keys == 'run'
               then
                  return true
               else
                  return false
               end
            end, 'Hydra: config.foreign_keys value could be either "warn" or "run"' }
         })
         vim.validate({
            color = { input.config.color, function(color)
               if not color then return true end
               local valid_colors = {
                  red = true, blue = true, amaranth = true, teal = true, pink = true
               }
               return valid_colors[color] or false
            end, 'Hydra: color value could be one of: red, blue, amaranth, teal, pink' }
         })
      end
      for _, map in ipairs(input.heads) do
         vim.validate({
            head = { map, function(kmap)
               local lhs, rhs, opts = kmap[1], kmap[2], kmap[3]
               if type(kmap) ~= 'table'
                  or type(lhs) ~= 'string'
                  or (rhs and type(rhs) ~= 'string' and type(rhs) ~= 'function')
                  or (opts and (type(opts) ~= 'table' or opts.desc == true))
               then
                  return false
               else
                  return true
               end
            end, 'Hydra: wrong head type'}
         })
      end
   end

   self.id = util.generate_id() -- Unique ID for each Hydra.
   self.name  = input.name
   self.config = vim.tbl_deep_extend('force', default_config, input.config or {})
   self.mode  = input.mode or 'n'
   self.body  = input.body
   self.options = options('hydra.options')

   getmetatable(self.options.bo).__index = util.add_hook_before(
      getmetatable(self.options.bo).__index,
      function(_, opt)
         assert(type(opt) ~= 'number',
            '[Hydra] vim.bo[bufnr] meta-aссessor in config.on_enter() function is forbiden, use "vim.bo" instead')
      end
   )
   getmetatable(self.options.wo).__index = util.add_hook_before(
      getmetatable(self.options.wo).__index,
      function(_, opt)
         assert(type(opt) ~= 'number',
            '[Hydra] vim.wo[winnr] meta-aссessor in config.on_enter() function is forbiden, use "vim.wo" instead')
      end
   )

   -- make Hydra buffer local
   if self.config.buffer and type(self.config.buffer) ~= 'number' then
      self.config.buffer = vim.api.nvim_get_current_buf()
   end

   -- Bring 'foreign_keys', 'exit' and 'color' options into line.
   local color = util.get_color_from_config(self.config.foreign_keys, self.config.exit)
   if color ~= 'red' and color ~= self.config.color then
      self.config.color = color
   elseif color ~= self.config.color then
      self.config.foreign_keys, self.config.exit = util.get_config_from_color(self.config.color)
   end

   if not self.body or self.config.exit then
      self.config.invoke_on_body = true
   end

   -- Table with all left hand sides of key mappings of the type `<Plug>...`.
   self.plug = setmetatable({}, {
      __index = function(t, key)
         t[key] = ('<Plug>(Hydra%s_%s)'):format(self.id, key)
         return t[key]
      end
   })

   self.heads = {};
   self.heads_spec = {}
   local has_exit_head = self.config.exit and true or nil
   for index, head in ipairs(input.heads) do
      local lhs, rhs, opts = head[1], head[2], head[3] or {}

      if opts.exit ~= nil then -- User explicitly passed `exit` parameter to the head
         color = util.get_color_from_config(self.config.foreign_keys, opts.exit)
         if opts.exit and has_exit_head == nil then
            has_exit_head = true
         end
      else
         opts.exit = self.config.exit
         color = self.config.color
      end

      local desc = opts.desc
      opts.desc = nil

      local func = rhs and function()
         local f = {} -- keys for feeding
         if opts.expr then
            if type(rhs) == 'function' then
               f.keys = rhs()
            elseif type(rhs) == 'string' then
               f.keys = vim.api.nvim_eval(rhs)
            end
         elseif type(rhs) == 'function' then
            rhs()
            return
         elseif type(rhs) == 'string' then
            f.keys = rhs
         end
         f.keys = termcodes(f.keys)
         f.mode = opts.remap and 'im' or 'in'
         vim.api.nvim_feedkeys(f.keys, f.mode, true)
      end

      self.heads[lhs] = { func, opts }

      self.heads_spec[lhs] = {
         index = index,
         color = color:gsub("^%l", string.upper), -- capitalize first letter
         desc = desc
      }
   end
   if not has_exit_head then
      self.heads['<Esc>'] = { nil, { exit = true }}
      self.heads_spec['<Esc>'] = {
         index = vim.tbl_count(self.heads),
         color = self.config.foreign_keys == 'warn' and 'Teal' or 'Blue',
         desc = 'exit'
      }
   end

   self.hint = hint(self, self.config.hint, input.hint)

   if self.config.color == 'pink' then
      self:_setup_pink_hydra()
   else
      if self.config.on_enter then
         local env = vim.tbl_deep_extend('force', getfenv(), {
            vim = { o = {}, go = {}, bo = {}, wo = {} }
         })
         env.vim.o  = self.options.o
         env.vim.go = self.options.go
         env.vim.bo = self.options.bo
         env.vim.wo = self.options.wo

         setfenv(self.config.on_enter, env)
      end
      if self.config.on_exit then
         local env = vim.tbl_deep_extend('force', getfenv(), {
            vim = { o = {}, go = {}, bo = {}, wo = {} }
         })
         env.vim.o  = util.disable_meta_accessor('o')
         env.vim.go = util.disable_meta_accessor('go')
         env.vim.bo = util.disable_meta_accessor('bo')
         env.vim.wo = util.disable_meta_accessor('wo')

         setfenv(self.config.on_exit, env)
      end
      self:_setup_hydra_keymaps()
   end
end

function Hydra:_setup_hydra_keymaps()
   self:_set_keymap(self.plug.wait, function() self:_leave() end)

   -- Define entering keymap if Hydra is called only on body keymap.
   if self.config.invoke_on_body and self.body then
      self:_set_keymap(self.body, function()
         self:_enter()
         self:_wait()
      end)
   end

   -- Define Hydra kyebindings.
   for head, map in pairs(self.heads) do
      local rhs, opts = map[1], map[2]

      -- Define enter mappings
      if not self.config.invoke_on_body and not opts.exit and not opts.private then
         self:_set_keymap(self.body..head, function()
            self:_enter()
            if rhs then rhs() end
            self:_wait()
         end)
      end

      -- Define exit mappings
      if opts.exit then -- blue head
         self:_set_keymap(self.plug.wait..head, function()
            self:exit()
            if rhs then rhs() end
         end)
      else
         self:_set_keymap(self.plug.wait..head, function()
            if rhs then rhs() end
            self:_wait()
         end)
      end

      -- Assumption:
      -- Special keys such as <C-u> are escaped with < and >, i.e.,
      -- key sequences doesn't directly contain any escape sequences.
      local keys = vim.fn.split(head, [[\(<[^<>]\+>\|.\)\zs]])
      for i = #keys-1, 1, -1 do
         local first_n_keys = table.concat(vim.list_slice(keys, 1, i))
         self:_set_keymap(self.plug.wait..first_n_keys, function() self:_leave() end)
      end
   end
end

function Hydra:_setup_pink_hydra()
   local available, KeyLayer = pcall(require, 'keymap-layer')
   if not available then
      vim.schedule(function() vim.notify_once(
         '[hyda.nvim] For pink hydra you need https://github.com/anuvyklack/keymap-layer.nvim package',
         vim.log.levels.ERROR)
      end)
      return false
   end

   local function create_layer_input_in_internal_form()
      local layer = util.unlimited_depth_table()
      layer.config = {
         debug = self.config.debug,
         buffer = self.config.buffer,
         on_enter = {
            function()
               _G.Hydra = self
               self.hint:show()
            end,
            self.config.on_enter
         },
         on_exit = {
            self.config.on_exit,
            function()
               self.hint:close()
               self.options:restore()
               vim.api.nvim_echo({}, false, {})  -- vim.cmd 'echo'
               _G.Hydra = nil
            end
         },
         timeout = self.config.timeout
      }

      local modes = type(self.mode) == 'table' and self.mode or { self.mode }
      self.body = termcodes(self.body)

      if self.config.invoke_on_body then
         for _, mode in ipairs(modes) do
            layer.enter_keymaps[mode][self.body] = {'<Nop>', {}}
         end
      end

      for head, map in pairs(self.heads) do
         head = termcodes(head)
         local rhs = map[1] or '<Nop>'
         local opts = map[2] and vim.deepcopy(map[2]) or {}
         local exit, private, head_modes = opts.exit, opts.private, opts.mode
         opts.color, opts.private, opts.exit, opts.modes = nil, nil, nil, nil
         if type(opts.desc) == 'boolean' then opts.desc = nil end

         if head_modes then
            head_modes = type(head_modes) == 'table' and head_modes or { head_modes }
         end

         for _, mode in ipairs(head_modes or modes) do
            if not self.config.invoke_on_body and not exit and not private then
               layer.enter_keymaps[mode][self.body..head] = { rhs, opts }
            end

            if exit then
               layer.exit_keymaps[mode][head] = { rhs, opts }
            else
               layer.layer_keymaps[mode][head] = { rhs, opts }
            end
         end
      end

      util.deep_unsetmetatable(layer)

      return layer
   end

   local function create_layer_input_in_public_form()
      local layer = { enter = {}, layer = {}, exit = {} }
      layer.config = {
         debug = self.config.debug,
         buffer = self.config.buffer,
         on_enter = {
            function()
               _G.Hydra = self
               self.hint:show()
            end,
            self.config.on_enter
         },
         on_exit = {
            self.config.on_exit,
            function()
               self.hint:close()
               self.options:restore()
               vim.api.nvim_echo({}, false, {})  -- vim.cmd 'echo'
               _G.Hydra = nil
            end
         },
         timeout = self.config.timeout
      }

      if self.config.invoke_on_body then
         layer.enter[1] = { self.mode, self.body }
      end

      for head, map in pairs(self.heads) do
         head = termcodes(head)
         local rhs  = map[1] or '<Nop>'
         local opts = map[2] and vim.deepcopy(map[2]) or {}
         local exit, private, head_modes = opts.exit, opts.private, opts.mode
         opts.color, opts.private, opts.exit, opts.mode = nil, nil, nil, nil

         local mode = self.mode
         if head_modes then
            mode = type(head_modes) == 'table' and head_modes or { head_modes }
         end

         if not self.config.invoke_on_body and not exit and not private then
            table.insert(layer.enter, { mode, self.body..head, rhs, opts })
         end

         if exit then
            table.insert(layer.exit, { mode, head, rhs, opts })
         else
            table.insert(layer.layer, { mode, head, rhs, opts })
         end
      end

      return layer
   end

   local layer = create_layer_input_in_internal_form()
   -- local layer = create_layer_input_in_public_form()

   self.layer = KeyLayer(layer)
end

function Hydra:_enter()
   if _G.Hydra then
      if _G.Hydra.layer then
         _G.Hydra.layer:exit()
      else
         _G.Hydra:_exit()
      end
   end
   _G.Hydra = self

   local o = self.options.o
   o.showcmd = false

   if self.config.timeout then
      o.timeout = true
      if type(self.config.timeout) == 'number' then
         o.timeoutlen = self.config.timeout
      end
   else
      o.timeout = false
   end
   o.ttimeout = not self.options.original.timeout and true
                or self.options.original.ttimeout

   if self.config.on_enter then self.config.on_enter() end

   self.hint:show()
end

---Programmatically activate hydra
function Hydra:activate()
   if self.layer then
      self.layer:enter()
   else
      self:_enter()
      self:_wait()
   end
end

-- Deactivate hydra
function Hydra:exit()
   self.options:restore()
   self.hint:close()
   if self.config.on_exit then self.config.on_exit() end
   _G.Hydra = nil
   vim.api.nvim_echo({}, false, {})  -- vim.cmd 'echo'
end

function Hydra:_wait()
   vim.api.nvim_feedkeys( termcodes(self.plug.wait), '', false)
end

function Hydra:_leave()
   if self.config.color == 'amaranth' then
      if vim.fn.getchar(1) ~= 0 then
         -- 'An Amaranth Hydra can only exit through a blue head'
         vim.api.nvim_echo({
            {'An '},
            {'Amaranth', 'HydraAmaranth'},
            {' Hydra can only exit through a blue head'}
         }, false, {})

         vim.fn.getchar()
         self:_wait()
      end
   elseif self.config.color == 'teal' then
      if vim.fn.getchar(1) ~= 0 then
         -- 'A Teal Hydra can only exit through one of its heads'
         vim.api.nvim_echo({
            {'A '},
            {'Teal', 'HydraTeal'},
            {' Hydra can only exit through one of its heads'}
         }, false, {})

         vim.fn.getchar()
         self:_wait()
      end
   else
      self:exit()
   end
end

function Hydra:_set_keymap(lhs, rhs, opts)
   local o = opts and vim.deepcopy(opts) or {}
   if not vim.tbl_isempty(o) then
      o.color = nil
      o.private = nil
      o.exit = nil
      if type(o.desc) == 'boolean' then o.desc = nil end
      o.nowait = nil
      o.mode = nil
   end
   o.buffer = self.config.buffer
   vim.keymap.set(self.mode, lhs, rhs, o)
end

function Hydra:_debug(...)
   if self.config.debug then
      vim.pretty_print(...)
   end
end

return Hydra
