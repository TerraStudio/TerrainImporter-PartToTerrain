local TerrainEnum = {}

TerrainEnum.Shape = {
  Ball = 'Ball',
  Block = 'Block',

  -- Roblox treats Cylinders differently for some reason.
  -- See: https://devforum.roblox.com/t/terrain-fillcylinder-rotating-incorrectly/336086
  -- Cylinder = Part with a CylinderMesh
  -- CylinderRotate = Part.Shape == Enum.PartType.Cylinder
  Cylinder = 'Cylinder',
  CylinderRotate = 'CylinderRotate',

  Wedge = 'Wedge',
  MeshPart = 'MeshPart',
}

TerrainEnum.ConvertError = {
  RegionTooLarge = 'RegionTooLarge',
  UnknownShape = 'UnknownShape',
  InvalidSize = 'InvalidSize',
}

return TerrainEnum
