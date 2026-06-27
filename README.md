<div align="center">
  <img src="https://user-images.githubusercontent.com/14226603/50402248-1828e200-0763-11e9-9b84-7e34f0bd8ef2.png">

  <h1>TerrainImporter V1.0</h1>
  <p>A specialized Roblox plugin for converting high-fidelity 3D meshes (GLB/OBJ) into Roblox Voxel Terrain.</p>
  <br>
  <p><b>Note:</b> This plugin is specifically designed and optimized for importing terrains that use 3D Mesh formats such as <b>OBJ</b> or <b>GLB/GLTF</b> (e.g. exported from Blender). It utilizes the EditableMesh API to accurately voxelize custom mesh geometry.</p>
</div>

## Features
- **Accurate Surface Voxelization**: Retains the 1:1 scale of imported MeshParts using the `EditableMesh` API.
- **Voxel Region Chunking**: Safely splits massive terrain chunks into 512x512 sub-regions to bypass Roblox voxel limits without crashing.
- **Batch Processing**: Convert dozens of imported chunks sequentially using `Shift + Click`.
- **Hollow Shell Optimization**: Generates surface voxels only to save memory and boost performance.

## Usage
1. Import your 3D chunks (`.glb` or `.gltf`) from Blender using the Roblox **3D Importer**.
2. Make sure the objects load into the workspace as `MeshPart`s.
3. Open the **TerrainImporter V1.0** plugin in the `Project Terra` toolbar.
4. Select a material (e.g. Grass).
5. Highlight all your `MeshPart` chunks in the Explorer.
6. Hold **`Shift`** and **Click** in the viewport to batch convert them!

## Tools used
- [React-lua](https://github.com/jsdotlua/react-lua) - UI Rendering
- [BasicState](https://github.com/csqrl/BasicState) - State Management
- [Rojo](https://github.com/rojo-rbx/rojo) - Syncing and compiling
- [Selene](https://github.com/Kampfkarren/selene) - Syntax checking

## Building the plugin
1. Ensure you have Git, Wally, and Rojo installed (`rokit install` recommended).
2. Clone the repo:
```
git clone https://github.com/TerraStudio/TerrainImporter-PartToTerrain.git
```
3. Install packages via Wally:
```
wally install
```
4. Build the plugin straight to your Roblox Studio local plugins folder:
```
rojo build -p TerrainImporterV1.0.rbxm
```

## Credits
- [TigerCaptain](https://roblox.com/users/19053090/profile) - Original concept
- [CloneTrooper1019](https://roblox.com/users/2032622/profile) - Helped with the original plugin
- [Valletta](https://twitter.com/valletta__) - Created the logo for this plugin
- [mkargus](https://github.com/mkargus/PartToTerrain) - Author of the original open-source plugin
- **Refitted by Project Terra** - Added Voxel Chunking & GLB/EditableMesh generation
