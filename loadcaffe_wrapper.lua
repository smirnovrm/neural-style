local ffi = require 'ffi'
require 'loadcaffe'
local C = loadcaffe.C

--[[
  Most of this function is copied from
  https://github.com/szagoruyko/loadcaffe/blob/master/loadcaffe.lua
  with some horrible horrible hacks added by Justin Johnson to
  make it possible to load VGG-19 without any CUDA dependency.
--]]
local function loadcaffe_load(prototxt_name, binary_name, backend)
  print("In loadcaffe_load")
  local backend = backend or 'nn'
  local handle = ffi.new('void*[1]')

  -- loads caffe model in memory and keeps handle to it in ffi
  local old_val = handle[1]
  C.loadBinary(handle, prototxt_name, binary_name)
  if old_val == handle[1] then return end

  -- transforms caffe prototxt to torch lua file model description and 
  -- writes to a script file
  local lua_name = prototxt_name..'.lua'

  -- C.loadBinary creates a .lua source file that builds up a table
  -- containing the layers of the network. As a horrible dirty hack,
  -- we'll modify this file when backend "nn-cpu" is requested by
  -- doing the following:
  --
  -- (1) Delete the lines that import cunn and inn, which are always
  --     at lines 2 and 4
  local model = nil
  if backend == 'nn-cpu' then
    C.convertProtoToLua(handle, lua_name, 'nn')
    local lua_name_cpu = prototxt_name..'.cpu.lua'
    local fin = assert(io.open(lua_name), 'r')
    local fout = assert(io.open(lua_name_cpu, 'w'))
    local line_num = 1
    while true do
      local line = fin:read('*line')
      if line == nil then break end
      if line_num ~= 2  and line_num ~= 4 then
        fout:write(line, '\n')
      end
      line_num = line_num + 1
    end
    fin:close()
    fout:close()
    model = dofile(lua_name_cpu)
  else
    if backend == "clnn" then
      C.convertProtoToLua(handle, lua_name, 'nn')
      local lua_name_opencl = prototxt_name..'.opencl.lua'
      local fin = assert(io.open(lua_name), 'r')
      local fout = assert(io.open(lua_name_opencl, 'w'))
      local line_num = 1
      while true do
        local line = fin:read('*line')
        if line == nil then break end
        --[[
        if string.find(line, "conv5_4") then
          line = line:gsub("512", "128", 2)
          print("Updated Line to: %s", line)
        elseif string.find(line, "fc6") then
          line = line:gsub("25088", "6272")
          print("Updated Line to: %s", line)
        end
        ]]--
        if line_num > 2 and line_num ~=4 then
          fout:write(line, '\n')
        elseif line_num == 1 then
          fout:write("require 'nn'", '\n')
          fout:write("require 'clnn'", '\n')
        end
        line_num = line_num + 1
      end
      fin:close()
      fout:close()
      model = dofile(lua_name_opencl)
    else
      C.convertProtoToLua(handle, lua_name, backend)
      model = dofile(lua_name)
    end
  end
  print("Finished proto to lua")

  -- goes over the list, copying weights from caffe blobs to torch tensor
  local net = nn.Sequential()
  local list_modules = model
  for i,item in ipairs(list_modules) do
    --print("In iteration %d", i)
    if item[2].weight then
      local w = torch.FloatTensor()
      local bias = torch.FloatTensor()
      C.loadModule(handle, item[1], w:cdata(), bias:cdata())
      if backend == 'ccn2' then
        w = w:permute(2,3,4,1)
      end
      item[2].weight:copy(w)
      item[2].bias:copy(bias)
    end
    net:add(item[2])
  end
  C.destroyBinary(handle)

  print("Finished iterations", backend)
  if backend == 'cudnn' or backend == 'ccn2' then
    net:cuda()
  elseif backend == 'clnn' then
    -- net:cl()
  end

  print("Finished network setup")
  return net
end

return {
  load = loadcaffe_load
}
