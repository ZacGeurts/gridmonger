import std/algorithm
import std/options
import std/sets
import std/sugar
import std/tables
import std/unicode

import with

import common
import level
import links
import regions
import utils/misc
import utils/naturalsort
import utils/rect


using m: Map

# {{{ newMap*()
proc newMap*(title, game, author, creationTime: string): Map =
  var m = new Map
  m.title        = title
  m.game         = game
  m.author       = author
  m.creationTime = creationTime

  m.levels = initOrderedTable[Natural, Level]()
  # Start with dirty until cleared
  m.levelsDirty = true

  m.links = initLinks()

  m.coordOpts = CoordinateOptions(
    origin:      coNorthWest,
    rowStyle:    csNumber,
    columnStyle: csNumber,
    rowStart:    1,
    columnStart: 1
  )

  m.sortedLevelIds   = @[]
  m.sortedLevelNames = @[]

  result = m

# }}}

# {{{ sortLevels*()
proc sortLevels*(m) =
  m.levels.sort(
    proc (a, b: tuple[levelId: Natural, level: Level]): int =
      var c = cmpNaturalIgnoreCase(a.level.locationName.toRunes,
                                   b.level.locationName.toRunes)
      if c != 0: return c

      c = cmp(b.level.elevation, a.level.elevation)
      if c != 0: return c

      return cmpNaturalIgnoreCase(a.level.levelName.toRunes,
                                  b.level.levelName.toRunes)
  )

  m.sortedLevelIds = collect:
    for id, _ in m.levels: id

  m.sortedLevelNames = collect:
    for _, level in m.levels: level.getDetailedName

# }}}
# {{{ hasLevels*()
func hasLevels*(m): bool =
  m.levels.len > 0

# }}}
# {{{ setLevel*()
proc setLevel*(m; l: Level) =
  m.levels[l.id] = l
  m.sortLevels
  m.levelsDirty = true

# }}}
# {{{ delLevel*()
proc delLevel*(m; levelId: Natural) =
  m.levels.del(levelId)
  m.sortLevels
  m.levelsDirty = true

# }}}

# {{{ coordOptsForLevel*()
func coordOptsForLevel*(m; levelId: Natural): CoordinateOptions =
  let l = m.levels[levelId]
  if l.overrideCoordOpts: l.coordOpts else: m.coordOpts

# }}}

# {{{ getRegionRect()
proc getRegionRect(m; levelId: Natural, rc: RegionCoords): Rect[Natural] =
  let l = m.levels[levelId]
  var r: Rect[Natural]

  with l.regionOpts:
    r.c1 = rc.col * colsPerRegion
    r.c2 = (r.c1 + colsPerRegion).clampMax(l.cols)

    case m.coordOptsForLevel(levelId).origin
    of coNorthWest:
      r.r1 = rc.row * rowsPerRegion
      r.r2 = (r.r1 + rowsPerRegion).clampMax(l.rows)

    of coSouthWest:
      r.r2 = (l.rows - rc.row*rowsPerRegion).clampMin(0)
      r.r1 = (r.r2.int - rowsPerRegion).clampMin(0)

  result = r

# }}}
# {{{ getRegionCoords*()
proc getRegionCoords*(m; loc: Location): RegionCoords =
  let
    l = m.levels[loc.levelId]

    row = case m.coordOptsForLevel(loc.levelId).origin
          of coNorthWest: loc.row
          of coSouthWest: ((l.rows-1).int - loc.row).clampMin(0)

  result.row = row     div l.regionOpts.rowsPerRegion
  result.col = loc.col div l.regionOpts.colsPerRegion

# }}}
# {{{ getRegionCenterLocation*()
proc getRegionCenterLocation*(m; levelId: Natural,
                              rc: RegionCoords): tuple[row, col: Natural] =
  let
    l = m.levels[levelId]
    r = m.getRegionRect(levelId, rc)

  let
    centerRow = (r.r1 + (r.r2-r.r1-1) div 2).clampMax(l.rows-1)
    centerCol = (r.c1 + (r.c2-r.c1-1) div 2).clampMax(l.cols-1)

  (centerRow.Natural, centerCol.Natural)

# }}}
# {{{ reallocateRegions*()
proc reallocateRegions*(m; levelId: Natural, oldCoordOpts: CoordinateOptions,
                        oldRegionOpts: RegionOptions, oldRegions: Regions) =

  let
    l = m.levels[levelId]
    coordOpts = m.coordOptsForLevel(levelId)
    flipVert = coordOpts.origin != oldCoordOpts.origin

  var index = 1

  l.regions = initRegions()

  for rc in l.regionCoords:
    let oldRc = if flipVert:
                  RegionCoords(row: l.regionRows(oldRegionOpts)-1 - rc.row,
                               col: rc.col)
                else: rc

    let region = oldRegions[oldRc]

    if region.isSome and not region.get.isUntitledRegion:
      l.regions[rc] = region.get
    else:
      let region = initRegion(name=l.regions.nextUntitledRegionName(index))
      l.regions[rc] = region

  l.regions.sortRegions

# }}}
# {{{ calcRegionResizeOffsets*()
proc calcRegionResizeOffsets*(
  m; levelId: Natural, newRows, newCols: Natural, anchor: Direction
 ): tuple[rowOffs, colOffs: int] =

  let l = m.levels[levelId]
  let srcRect = getSrcRectAlignedToDestRect(l, newRows, newCols, anchor)

  with l.regionOpts:
    result.colOffs = -srcRect.c1 div colsPerRegion

    result.rowOffs = (case m.coordOptsForLevel(levelId).origin
                      of coNorthWest: -srcRect.r1
                      of coSouthWest:
                        -(newRows - srcRect.r2)) div rowsPerRegion

# }}}

# {{{ regionNotes*()
iterator regionNotes*(
  m; levelId: Natural, rc: RegionCoords
): tuple[loc: Location, note: Annotation] =

  let
    level = m.levels[levelId]
    rect  = m.getRegionRect(levelId, rc)

  for note in level.allNotes:
    if rect.contains(note.row, note.col):
      yield (Location(levelId: levelId, row: note.row, col: note.col),
             note.annotation)

# }}}
# {{{ hasNote*()
proc hasNote*(m; loc: Location): bool {.inline.} =
  m.levels[loc.levelId].hasNote(loc.row, loc.col)

# }}}
# {{{ getNote*()
proc getNote*(m; loc: Location): Option[Annotation] {.inline.} =
  m.levels[loc.levelId].getNote(loc.row, loc.col)

# }}}
# {{{ hasLabel*()
proc hasLabel*(m; loc: Location): bool {.inline.} =
  m.levels[loc.levelId].hasLabel(loc.row, loc.col)

# }}}
# {{{ getLabel*()
proc getLabel*(m; loc: Location): Option[Annotation] {.inline.} =
  m.levels[loc.levelId].getLabel(loc.row, loc.col)

# }}}

# {{{ eraseCellLinks*()
proc eraseCellLinks*(m; loc: Location) =
  m.links.delBySrc(loc)
  m.links.delByDest(loc)

# }}}
# {{{ eraseCell*()
proc eraseCell*(m; loc: Location, preserveLabel: bool) =
  alias(l, m.levels[loc.levelId])
  let label = m.getLabel(loc)

  m.levels[loc.levelId].eraseCell(loc.row, loc.col)
  m.eraseCellLinks(loc)

  if preserveLabel and label.isSome:
    l.setAnnotation(loc.row, loc.col, label.get)

# }}}
# {{{ eraseCellWalls*()
proc eraseCellWalls*(m; loc: Location) =
  m.levels[loc.levelId].eraseCellWalls(loc.row, loc.col)

# }}}

# {{{ isEmpty*()
proc isEmpty*(m; loc: Location): bool {.inline.} =
  m.levels[loc.levelId].isEmpty(loc.row, loc.col)

# }}}
# {{{ getFloor*()
proc getFloor*(m; loc: Location): Floor {.inline.} =
  m.levels[loc.levelId].getFloor(loc.row, loc.col)

# }}}
# {{{ setFloor*()
proc setFloor*(m; loc: Location, f: Floor) =
  m.levels[loc.levelId].setFloor(loc.row, loc.col, f)
  m.eraseCellLinks(loc)

# }}}
# {{{ clearFloor*()
proc clearFloor*(m; loc: Location) =
  m.levels[loc.levelId].clearFloor(loc.row, loc.col)
  m.eraseCellLinks(loc)

# }}}
# {{{ getFloorOrientation*()
proc getFloorOrientation*(m; loc: Location): CardinalDir {.inline.} =
  m.levels[loc.levelId].getFloorOrientation(loc.row, loc.col)

# }}}
# {{{ setFloorOrientation*()
proc setFloorOrientation*(m; loc: Location, dir: CardinalDir) =
  m.levels[loc.levelId].setFloorOrientation(loc.row, loc.col, dir)

# }}}
# {{{ guessFloorOrientation*()
proc guessFloorOrientation*(m; loc: Location): CardinalDir =
  m.levels[loc.levelId].guessFloorOrientation(loc.row, loc.col)

# }}}
# {{{ getFloorColor*()
proc getFloorColor*(m; loc: Location): Natural {.inline.} =
  m.levels[loc.levelId].getFloorColor(loc.row, loc.col)

# }}}
# {{{ setFloorColor*()
proc setFloorColor*(m; loc: Location,
                    floorColor: Natural) =
  m.levels[loc.levelId].setFloorColor(loc.row, loc.col, floorColor.byte)

# }}}

# {{{ getWall*()
proc getWall*(m; loc: Location, dir: CardinalDir): Wall {.inline.} =
  m.levels[loc.levelId].getWall(loc.row, loc.col, dir)

# }}}
# {{{ setWall*()
proc setWall*(m; loc: Location, dir: CardinalDir, w: Wall) =
  m.levels[loc.levelId].setWall(loc.row, loc.col, dir, w)

# }}}
# {{{ canSetWall*()
proc canSetWall*(m; loc: Location, dir: CardinalDir): bool =
  m.levels[loc.levelId].canSetWall(loc.row, loc.col, dir)

# }}}

# {{{ hasTrail*()
proc hasTrail*(m; loc: Location): bool =
  m.levels[loc.levelId].hasTrail(loc.row, loc.col)

# }}}
# {{{ setTrail*()
proc setTrail*(m; loc: Location, t: bool) =
  m.levels[loc.levelId].setTrail(loc.row, loc.col, t)

# }}}

# {{{ excavateTunnel*()
proc excavateTunnel*(m; loc: Location, floorColor: Natural,
                     dir: Option[CardinalDir] = CardinalDir.none,
                     prevLoc: Option[Location] = Location.none,
                     prevDir: Option[CardinalDir] = CardinalDir.none) =
  alias(l, m.levels[loc.levelId])
  alias(c, loc.col)
  alias(r, loc.row)

  m.eraseCell(loc, preserveLabel=true)
  m.setFloor(loc, fBlank)
  m.setFloorColor(loc, floorColor)

  if dir.isSome and prevDir.isSome and
     dir.get.isHoriz != prevDir.get.isHoriz:
    m.excavateTunnel(prevLoc.get, floorColor)

  var wallDirs = @[dirN, dirS, dirE, dirW]
  if dir.isSome:
    wallDirs.delete(wallDirs.find(dir.get))

  for d in wallDirs:
    if l.isNeighbourCellEmpty(r, c, {d}):
      m.setWall(loc, d, wWall)
    else:
      m.setWall(loc, d, wNone)

# }}}

# {{{ getLinkedLocations*()
proc getLinkedLocations*(m; loc: Location): HashSet[Location] =
  let dest = m.links.getBySrc(loc)
  if dest.isSome:
    if not isSpecialLevelId(dest.get.levelId):
      result.incl(dest.get)
  else:
    let srcs = m.links.getByDest(loc)
    if srcs.isSome:
      for src in srcs.get:
        if isSpecialLevelId(src.levelId):
          continue
        result.incl(src)

# }}}
# {{{ normaliseLinkedStairs*()
proc normaliseLinkedStairs*(m; levelId: Natural) =
  let l = m.levels[levelId]

  for r in 0..<l.rows:
    for c in 0..<l.cols:
      let f = l.getFloor(r,c)

      if f in LinkStairs:
        let src = Location(levelId: levelId, row: r, col: c)
        let dst = m.getLinkedLocations(src)
        if dst.len > 0:
          assert dst.len == 1, "Stairs should not have linked multiple locations"
          let dst = dst.first.get

          let srcElevation = m.levels[src.levelId].elevation
          let dstElevation = m.levels[dst.levelId].elevation

          proc setFloors(thisFloor, thatFloor: Floor) =
            m.levels[src.levelId].setFloor(src.row, src.col, thisFloor)
            m.levels[dst.levelId].setFloor(dst.row, dst.col, thatFloor)

          if   srcElevation > dstElevation: setFloors(fStairsDown, fStairsUp)
          elif srcElevation < dstElevation: setFloors(fStairsUp, fStairsDown)

# }}}
# {{{ deleteLinksFromOrToLevel*()
proc deleteLinksFromOrToLevel*(m; levelId: Natural) =
  var linksToDelete = m.links.filterByLevel(levelId)
  for src in linksToDelete.sources:
    m.links.delBySrc(src)

# }}}

# {{{ newLevelFrom*()
proc newLevelFrom*(m; srcLevelId: Natural, srcRect: Rect[Natural],
                   overrideId: Option[Natural] = Natural.none): Level =

  let src = m.levels[srcLevelId]
  alias(ro, src.regionOpts)

  var dest = newLevelFrom(src, srcRect, overrideId=overrideId)

  # Copy regions
  let (copyRect, _, _) = calcNewLevelFromParams(src, srcRect)

  let
    rowOffs = (case m.coordOptsForLevel(srcLevelId).origin
               of coNorthWest: copyRect.r1
               of coSouthWest: src.rows - copyRect.r2) div ro.rowsPerRegion

    colOffs = copyRect.c1 div ro.colsPerRegion

  dest.regions = initRegionsFrom(src.some, dest, rowOffs, colOffs)
  result = dest
# }}}

# }}}

# vim: et:ts=2:sw=2:fdm=marker
