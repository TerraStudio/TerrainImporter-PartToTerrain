-- MeshToTerrain.luau
-- Separated from TerrainConverter to avoid --!native incompatibility with task.wait()
-- This module handles MeshPart → Terrain conversion using EditableMesh API
-- with Voxel Region Chunking, Progress Indicator, and CPU Yielding.

local Constants = require(script.Parent.Constants)
local Settings = require(script.Parent.Settings)

local TerrainEnum = require(script.Parent.TerrainEnum)

local AssetService = game:GetService("AssetService")

local RESOLUTION = Constants.VOXEL_RESOLUTION
local MAX_CHUNK_VOXELS = 128 -- max voxels per axis per sub-region (128^3 = ~2M, well under 4M limit)
local MAX_CHUNK_STUDS = MAX_CHUNK_VOXELS * RESOLUTION -- 512 studs

local MeshToTerrain = {}

--------------------------------------------------------------------------------
-- Triangle Rasterization (surface only / hollow)
-- Samples points along the surface of a triangle and marks corresponding voxels
--------------------------------------------------------------------------------
local function rasterizeTriangleToDict(v1: Vector3, v2: Vector3, v3: Vector3, filledVoxels: { [number]: { [number]: { [number]: any } } }, yieldCheck: (() -> ())?)
  local v12 = v2 - v1
  local v13 = v3 - v1
  
  local normal = v12:Cross(v13).Unit
  if normal ~= normal or normal.Magnitude == 0 then
    normal = Vector3.new(0, 1, 0)
  end

  -- Menggunakan stepSize = 2.0 (setengah RESOLUTION) untuk performa 4x lebih cepat
  -- tanpa mengorbankan akurasi (diagonal 2x2 = 2.8, masih < 4)
  local stepSize = 2.0
  
  local stepsU = math.max(1, math.ceil(v12.Magnitude / stepSize))
  local stepsV = math.max(1, math.ceil(v13.Magnitude / stepSize))

  local pixelCount = 0

  for i = 0, stepsU do
    local u = i / stepsU
    
    -- Scale the number of V steps proportionally to the remaining width (1 - u)
    local currentStepsV = math.max(1, math.ceil(stepsV * (1 - u)))
    
    for j = 0, currentStepsV do
      pixelCount = pixelCount + 1
      if pixelCount % 5000 == 0 and yieldCheck then
        yieldCheck()
      end

      local v = (j / currentStepsV) * (1 - u)
      local p = v1 + v12 * u + v13 * v

      local vx = math.floor(p.X / RESOLUTION)
      local vy = math.floor(p.Y / RESOLUTION)
      local vz = math.floor(p.Z / RESOLUTION)

      -- Safety check for NaN or Infinity
      if vx ~= vx or vy ~= vy or vz ~= vz or math.abs(vx) == math.huge or math.abs(vy) == math.huge or math.abs(vz) == math.huge then
        continue
      end

      if not filledVoxels[vx] then
        filledVoxels[vx] = {}
      end
      if not filledVoxels[vx][vz] then
        filledVoxels[vx][vz] = {}
      end
      
      local currentTop = filledVoxels[vx][vz][vy]

      if type(currentTop) == "number" then
        if p.Y > currentTop then
          filledVoxels[vx][vz][vy] = p.Y
        end
      else
        -- Selalu prioritaskan exact height (p.Y) di atas solid fill (true)
        -- agar presisi fraksional (anti-terasering) tidak hilang.
        filledVoxels[vx][vz][vy] = p.Y
      end

      -- Selalu pastikan kedalaman shell solid ke arah DALAM (-normal) DAN ke BAWAH (-Y).
      -- Kombinasi ini sangat krusial untuk mencegah bolong pada tebing curam (inward) 
      -- dan memperbaiki masalah normals terbalik dari Blender / sudut lembah (downward).
      local FILL_DEPTH = 4
      for depth = 1, FILL_DEPTH do
        -- 1. Fill Inward (Mencegah tebing vertikal terhapus blur)
        local inwardP = p - normal * (depth * RESOLUTION)
        local ivx = math.floor(inwardP.X / RESOLUTION)
        local ivy = math.floor(inwardP.Y / RESOLUTION)
        local ivz = math.floor(inwardP.Z / RESOLUTION)

        if not filledVoxels[ivx] then
          filledVoxels[ivx] = {}
        end
        if not filledVoxels[ivx][ivz] then
          filledVoxels[ivx][ivz] = {}
        end

        -- Hanya isi bagian dalam jika kosong. Jangan timpa p.Y permukaan!
        if filledVoxels[ivx][ivz][ivy] == nil then
           filledVoxels[ivx][ivz][ivy] = true
        end

        -- 2. Fill Downward (Mencegah sudut lembah/normals terbalik terhapus blur)
        local belowVy = vy - depth
        if filledVoxels[vx][vz][belowVy] == nil then
           filledVoxels[vx][vz][belowVy] = true
        end
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Write a sub-region of voxels to terrain
--------------------------------------------------------------------------------
local function writeSubRegion(
  subMin: Vector3,
  subMax: Vector3,
  material: Enum.Material,
  preserveTerrain: boolean?,
  filledVoxels: { [number]: { [number]: { [number]: any } } },
  reportProgress: ((string) -> ())?,
  chunkString: string?
)
  local region = Region3.new(subMin, subMax):ExpandToGrid(RESOLUTION)
  local regionMin = region.CFrame.Position - region.Size / 2

  local materialVoxels, occupancyVoxels = workspace.Terrain:ReadVoxels(region, RESOLUTION)
  local regionSize = materialVoxels.Size

  if reportProgress and chunkString then
    reportProgress("Generating voxel data for " .. chunkString .. "...")
  end

  local modified = false

  for x = 1, regionSize.X do
    local worldVx = math.floor((regionMin.X + (x - 0.5) * RESOLUTION) / RESOLUTION)

    for y = 1, regionSize.Y do
      local worldVy = math.floor((regionMin.Y + (y - 0.5) * RESOLUTION) / RESOLUTION)

      for z = 1, regionSize.Z do
        local worldVz = math.floor((regionMin.Z + (z - 0.5) * RESOLUTION) / RESOLUTION)

        local voxelData = filledVoxels[worldVx] and filledVoxels[worldVx][worldVz] and filledVoxels[worldVx][worldVz][worldVy]
        if voxelData ~= nil then
          local cellOccupancy = 1
          if type(voxelData) == "number" then
            -- Calculate fractional occupancy based on how far p.Y is inside the voxel
            local voxelBottomY = worldVy * RESOLUTION
            -- We want a value between 0.1 and 1
            cellOccupancy = math.clamp((voxelData - voxelBottomY) / RESOLUTION, 0.1, 1)
          else
            -- It's true (solid)
            cellOccupancy = 1
          end

          if preserveTerrain then
            local currentOccupancy = occupancyVoxels[x][y][z]
            if cellOccupancy > currentOccupancy then
              occupancyVoxels[x][y][z] = cellOccupancy
            end
            local cellMaterial = materialVoxels[x][y][z]
            if cellMaterial == Enum.Material.Air then
              materialVoxels[x][y][z] = material
            end
          else
            occupancyVoxels[x][y][z] = cellOccupancy
            materialVoxels[x][y][z] = material
          end
          modified = true
        end
      end
    end
  end

  if modified then
    -- =========================================================================
    -- FAST POST-PROCESSING: Separable Box Blur (Smoothing)
    -- O(N) Algorithmic complexity for instant processing even on huge scales.
    -- Radius 1 (3x3x3 filter) untuk kehalusan yang natural tanpa menghilangkan detail.
    -- =========================================================================
    local R = 1
    local passes = 1
    if Settings:Get("ExtraSmoothing") then
      passes = 3
    end

    for _ = 1, passes do
      -- Pass 1: Blur along X
      local tempX = table.create(regionSize.X, 0)
    for y = 1, regionSize.Y do
      for z = 1, regionSize.Z do
        for x = 1, regionSize.X do
          tempX[x] = occupancyVoxels[x][y][z]
        end
        for x = 1, regionSize.X do
          local sum = 0
          local minK = x - R
          if minK < 1 then
            minK = 1
          end
          local maxK = x + R
          if maxK > regionSize.X then
            maxK = regionSize.X
          end
          for k = minK, maxK do
            sum = sum + tempX[k]
          end
          occupancyVoxels[x][y][z] = sum / (maxK - minK + 1)
        end
      end
    end

    -- Pass 2: Blur along Y
    local tempY = table.create(regionSize.Y, 0)
    for x = 1, regionSize.X do
      for z = 1, regionSize.Z do
        for y = 1, regionSize.Y do
          tempY[y] = occupancyVoxels[x][y][z]
        end
        for y = 1, regionSize.Y do
          local sum = 0
          local minK = y - R
          if minK < 1 then
            minK = 1
          end
          local maxK = y + R
          if maxK > regionSize.Y then
            maxK = regionSize.Y
          end
          for k = minK, maxK do
            sum = sum + tempY[k]
          end
          occupancyVoxels[x][y][z] = sum / (maxK - minK + 1)
        end
      end
    end

    -- Pass 3: Blur along Z
    local tempZ = table.create(regionSize.Z, 0)
    for x = 1, regionSize.X do
      for y = 1, regionSize.Y do
        for z = 1, regionSize.Z do
          tempZ[z] = occupancyVoxels[x][y][z]
        end
        for z = 1, regionSize.Z do
          local sum = 0
          local minK = z - R
          if minK < 1 then
            minK = 1
          end
          local maxK = z + R
          if maxK > regionSize.Z then
            maxK = regionSize.Z
          end
          for k = minK, maxK do
            sum = sum + tempZ[k]
          end
          occupancyVoxels[x][y][z] = sum / (maxK - minK + 1)
        end
      end
    end
    end -- end of blurPass loop

    -- Apply blurred materials fix-up
    for x = 1, regionSize.X do
      for y = 1, regionSize.Y do
        for z = 1, regionSize.Z do
          local occ = occupancyVoxels[x][y][z]
          local oldMat = materialVoxels[x][y][z]
          
          if occ > 0.1 and oldMat == Enum.Material.Air then
            materialVoxels[x][y][z] = material
          elseif occ < 0.05 and oldMat ~= Enum.Material.Air then
            materialVoxels[x][y][z] = Enum.Material.Air
            occupancyVoxels[x][y][z] = 0
          end
        end
      end
    end

    if reportProgress and chunkString then
      reportProgress("Writing terrain to world for " .. chunkString .. "...")
    end
    workspace.Terrain:WriteVoxels(region, RESOLUTION, materialVoxels, occupancyVoxels)
  end
end

--------------------------------------------------------------------------------
-- Main conversion function
-- Converts a MeshPart to terrain using EditableMesh triangle rasterization
-- with automatic region chunking for large meshes
--------------------------------------------------------------------------------
function MeshToTerrain:Convert(
  part: BasePart,
  material: Enum.Material,
  cframe: CFrame,
  size: Vector3,
  preserveTerrain: boolean?,
  progressCallback: ((message: string) -> ())?
): (boolean, string?)
  local function reportProgress(msg: string)
    if progressCallback then
      progressCallback(msg)
    end
    print("[PartToTerrain]", msg)
  end

  -- 1. Create EditableMesh from MeshPart
  reportProgress("Loading mesh geometry...")
  local success, result = pcall(function()
    local meshId = (part :: MeshPart).MeshId
    local meshContent = Content.fromUri(meshId)
    return AssetService:CreateEditableMeshAsync(meshContent)
  end)
  local editableMesh = result :: any

  if not success or not editableMesh then
    warn("[PartToTerrain] Failed to create EditableMesh:", tostring(result))
    return false, TerrainEnum.ConvertError.UnknownShape
  end

  -- 2. Calculate scale factor (1:1 with Blender)
  -- EditableMesh vertices are in local space relative to MeshSize
  local scaleFactor = size
  if part:IsA("MeshPart") then
    local meshSize = (part :: MeshPart).MeshSize
    local sx = meshSize.X == 0 and 1 or (size.X / meshSize.X)
    local sy = meshSize.Y == 0 and 1 or (size.Y / meshSize.Y)
    local sz = meshSize.Z == 0 and 1 or (size.Z / meshSize.Z)
    scaleFactor = Vector3.new(sx, sy, sz)
  end

  -- 3. Cache all vertices in world space
  reportProgress("Caching vertices...")
  local vertices: { [any]: Vector3 } = {}
  local vertIds = editableMesh:GetVertices()
  for _, id in ipairs(vertIds) do
    local localPos = editableMesh:GetPosition(id)
    local scaledPos = localPos * scaleFactor
    vertices[id] = cframe * scaledPos
  end
  reportProgress(string.format("Cached %d vertices.", #vertIds))

  -- 4. Rasterize all triangles into a sparse voxel dictionary
  -- filledVoxels[vx][vz][vy] = exactHeight | true (solid)
  local filledVoxels: { [number]: { [number]: { [number]: any } } } = {}
  local faces = editableMesh:GetFaces()
  local totalFaces = #faces
  local faceCount = 0

  reportProgress(string.format("Rasterizing %d faces...", totalFaces))

  local lastYield = os.clock()
  local function yieldCheck()
    if os.clock() - lastYield > 0.05 then
      task.wait()
      lastYield = os.clock()
    end
  end

  for _, faceId in ipairs(faces) do
    local faceVerts = editableMesh:GetFaceVertices(faceId)
    if #faceVerts >= 3 then
      -- Triangulate in case it's a polygon with > 3 vertices
      for i = 2, #faceVerts - 1 do
        local p1 = vertices[faceVerts[1]]
        local p2 = vertices[faceVerts[i]]
        local p3 = vertices[faceVerts[i + 1]]
        if p1 and p2 and p3 then
          rasterizeTriangleToDict(p1, p2, p3, filledVoxels, yieldCheck)
        end
      end
    end

    faceCount = faceCount + 1
    if faceCount % 500 == 0 then
      reportProgress(string.format("Rasterizing faces... %d/%d (%.0f%%)", faceCount, totalFaces, (faceCount / totalFaces) * 100))
      yieldCheck()
    end
  end

  reportProgress("Rasterization complete. Writing terrain...")

  -- 5. Calculate overall AABB from filled voxels
  local minVx, minVy, minVz = math.huge, math.huge, math.huge
  local maxVx, maxVy, maxVz = -math.huge, -math.huge, -math.huge

  for vx, zTable in pairs(filledVoxels) do
    if vx < minVx then
      minVx = vx
    end
    if vx > maxVx then
      maxVx = vx
    end
    for vz, yTable in pairs(zTable) do
      if vz < minVz then
        minVz = vz
      end
      if vz > maxVz then
        maxVz = vz
      end
      for vy, _ in pairs(yTable) do
        if vy < minVy then
          minVy = vy
        end
        if vy > maxVy then
          maxVy = vy
        end
      end
    end
  end

  if minVx == math.huge then
    warn("[PartToTerrain] No voxels were generated from the mesh.")
    return false, TerrainEnum.ConvertError.InvalidSize
  end

  -- Convert voxel indices to world coordinates
  local worldMin = Vector3.new(minVx * RESOLUTION, minVy * RESOLUTION, minVz * RESOLUTION)
  local worldMax = Vector3.new((maxVx + 1) * RESOLUTION, (maxVy + 1) * RESOLUTION, (maxVz + 1) * RESOLUTION)

  -- 6. Split into sub-regions (chunking) and write terrain
  local totalChunksX = math.ceil((worldMax.X - worldMin.X) / MAX_CHUNK_STUDS)
  local totalChunksY = math.ceil((worldMax.Y - worldMin.Y) / MAX_CHUNK_STUDS)
  local totalChunksZ = math.ceil((worldMax.Z - worldMin.Z) / MAX_CHUNK_STUDS)
  local totalChunks = totalChunksX * totalChunksY * totalChunksZ
  local chunksDone = 0

  for cx = 0, totalChunksX - 1 do
    for cy = 0, totalChunksY - 1 do
      for cz = 0, totalChunksZ - 1 do
        local subMin = Vector3.new(
          worldMin.X + cx * MAX_CHUNK_STUDS,
          worldMin.Y + cy * MAX_CHUNK_STUDS,
          worldMin.Z + cz * MAX_CHUNK_STUDS
        )
        local subMax = Vector3.new(
          math.min(worldMin.X + (cx + 1) * MAX_CHUNK_STUDS, worldMax.X),
          math.min(worldMin.Y + (cy + 1) * MAX_CHUNK_STUDS, worldMax.Y),
          math.min(worldMin.Z + (cz + 1) * MAX_CHUNK_STUDS, worldMax.Z)
        )

        writeSubRegion(subMin, subMax, material, preserveTerrain, filledVoxels)

        chunksDone = chunksDone + 1
        if totalChunks > 1 then
          reportProgress(string.format("Writing terrain sub-region %d/%d...", chunksDone, totalChunks))
          task.wait()
        end
      end
    end
  end

  reportProgress("Terrain conversion complete!")
  return true
end

return MeshToTerrain
