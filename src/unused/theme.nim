import math
import options
import parsecfg
import streams
import strformat

import nanovg
import with

import cfghelper
import common
import fieldlimits
import hocon
import macros
import strutils
import utils


proc `$`(c: Color): string =
  let
    r = round(c.r * 255).int
    g = round(c.g * 255).int
    b = round(c.b * 255).int
    a = round(c.a * 255).int

  fmt"#{r:02x}{g:02x}{b:02x}{a:02x}"


proc styleClassName(name: string): string =
  name.capitalizeAscii() & "Style"

proc mkPublicName(name: string): NimNode =
  nnkPostfix.newTree(
    newIdentNode("*"), newIdentNode(name)
  )

proc mkProperty(name: string, typ: NimNode): NimNode =
  nnkIdentDefs.newTree(
    mkPublicName(name), typ, newEmptyNode()
  )

proc mkRefObjectTypeDef(name: string, recList: NimNode): NimNode =
  nnkTypeDef.newTree(
    mkPublicName(name),
    newEmptyNode(),

    nnkRefTy.newTree(
      nnkObjectTy.newTree(
        newEmptyNode(),
        newEmptyNode(),
        recList
      )
    )
  )

proc makeStyleTypeDef(name: string, props: seq[(string, NimNode)]): NimNode =
  var recList = nnkRecList.newTree
  for propName, propType in props:
    recList.add(
      mkProperty(propName, propType)
    )

  result = mkRefObjectTypeDef(
    styleClassName(name),
    recList
  )

proc handleProperty(
  prop: NimNode,
  configSectionName: string,
  sectionNameSym, subsectionNameSym: NimNode
): (string, NimNode, NimNode, NimNode) =

  prop[0].expectKind nnkIdent
  let propName = prop[0].strVal

  let propParamsStmt = prop[1]

  var propType: NimNode
  case propParamsStmt[0].kind:
  of nnkIdent:  # no default provided
    propType = propParamsStmt[0]

  of nnkBracketExpr:  # no default provided
    propType = propParamsStmt[0]
    assert propType[0] == newIdentNode("array")
    assert propType[2] == newIdentNode("Color")

  of nnkInfix:  # default provided
    let propParams = propParamsStmt[0]
    propParams.expectLen 3

    assert propParams[0] == newIdentNode("|")
    propType = propParams[1]

  else:
    error("Invalid property definition: " & $propParamsStmt[0].kind)

  # Append loader statement
  let propNameSym = newIdentNode(propName)

  let toProp = quote do:
    result.`sectionNameSym`.`subsectionNameSym`.`propNameSym`

  let fromProp = quote do:
    theme.`sectionNameSym`.`subsectionNameSym`.`propNameSym`

  var parseThemeFrag = nnkStmtList.newTree
  var writeThemeFrag = nnkStmtList.newTree

  if propType.kind == nnkIdent:
    case propType.strVal
    of "string", "bool", "Color", "float":
      let getter = newIdentNode("get" & propType.strVal.capitalizeAscii())

      parseThemeFrag.add quote do:
        config.`getter`(`configSectionName`, `propName`, `toProp`)

      writeThemeFrag.add quote do:
        result.setSectionKey(`configSectionName`, `propName`,
                             $`fromProp`)

    else:  # enum
      parseThemeFrag.add  quote do:
        getEnum[`propType`](config, `configSectionName`, `propName`,
                            `toProp`)

      writeThemeFrag.add  quote do:
        result.setSectionKey(`configSectionName`, `propName`,
                             $`fromProp`)

  elif propType.kind == nnkBracketExpr:
    let propType = propParamsStmt[0]
    assert propType[0] == newIdentNode("array")
    assert propType[2] == newIdentNode("Color")
    let numColors = propType[1].intVal

    for i in 1..numColors:
      let propNameN = propName & $i
      let index = newIntLitNode(i-1)
      parseThemeFrag.add  quote do:
        config.getColor(`configSectionName`, `propNameN`,
                        `toProp`[`index`])

      writeThemeFrag.add quote do:
        result.setSectionKey(
          `configSectionName`, `propNameN`,
           $`fromProp`[`index`]
         )

  else:
    error("Invalid property type: " & $propType.kind)

  result = (propName, propType, parseThemeFrag, writeThemeFrag)


macro defineTheme(arg: untyped): untyped =
  arg.expectKind nnkStmtList

  var typeSection = nnkTypeSection.newTree
  var themeStyleRecList = nnkRecList.newTree
  var parseThemeBody = nnkStmtList.newTree
  var writeThemeBody = nnkStmtList.newTree

  # Sections
  for section in arg:
    section.expectKind nnkCall
    section.expectLen 2

    section[0].expectKind nnkIdent
    let sectionName = section[0].strVal

    let sectionNameSym = newIdentNode(sectionName)
    let sectionClassNameSym = newIdentNode(styleClassName(sectionName))

    parseThemeBody.add quote do:
      result.`sectionNameSym` = new `sectionClassNameSym`

    section[1].expectKind nnkStmtList

    var sectionPropsToAdd = newSeq[(string, NimNode)]()

    # Sub-sections
    for subsection in section[1]:
      subsection.expectKind nnkCall
      subsection.expectLen 2

      subsection[0].expectKind nnkIdent
      let subsectionName = subsection[0].strVal
      let subsectionNameSym = newIdentNode(subsectionName)

      let prefixedSubsectionName = sectionName & subsectionName.capitalizeAscii()
      let subsectionClassNameSym = newIdentNode(styleClassName(prefixedSubsectionName))

      let propsList = subsection[1]

      var propsToAdd = newSeq[(string, NimNode)]()

      let configSectionName = sectionName & "." & subsectionName

      parseThemeBody.add quote do:
        result.`sectionNameSym`.`subsectionNameSym` = new `subsectionClassNameSym`


      # Properties
      for prop in propsList:
        let (propName, propType, parseThemeFrag, writeThemeFrag) = handleProperty(
          prop,
          configSectionName,
          sectionNameSym, subsectionNameSym
        )
        propsToAdd.add((propName, propType))
        parseThemeBody.add(parseThemeFrag)
        writeThemeBody.add(writeThemeFrag)

      typeSection.add(
        makeStyleTypeDef(prefixedSubsectionName, propsToAdd)
      )

      let sectionPropType = newIdentNode(styleClassName(prefixedSubsectionName))
      sectionPropsToAdd.add((subsectionName, sectionPropType))

    typeSection.add(
      makeStyleTypeDef(sectionName, sectionPropsToAdd)
    )

    themeStyleRecList.add(
      mkProperty(sectionName, newIdentNode(styleClassName(sectionName)))
    )

  typeSection.add(
    mkRefObjectTypeDef("ThemeStyle", themeStyleRecList)
  )

  let config = newIdentNode("config")
  let theme = newIdentNode("theme")

  result = quote do:
    `typeSection`

    proc parseTheme(`config`: Config): ThemeStyle =
      result = new ThemeStyle
      `parseThemeBody`

    proc writeTheme(`theme`: ThemeStyle): Config =
      result = newConfig()
      `writeThemeBody`

#  echo result.repr


include themedef


const
  UiDialogCornerRadiusLimits*     = floatLimits(min=   0.0, max=20.0)
  UiDialogOuterBorderWidthLimits* = floatLimits(min=   0.0, max=30.0)
  UiDialogInnerBorderWidthLimits* = floatLimits(min=   0.0, max=30.0)
  UiDialogShadowXOffsetLimits*    = floatLimits(min= -10.0, max=10.0)
  UiDialogShadowYOffsetLimits*    = floatLimits(min= -10.0, max=10.0)
  UiDialogShadowFeatherLimits*    = floatLimits(min=   0.0, max=50.0)

  UiWidgetCornerRadiusLimits* = floatLimits(min=0.0, max=12.0)

  LevelBackgroundHatchWidthLimits*         = floatLimits(min=0.5, max=10.0)
  LevelBackgroundHatchSpacingFactorLimits* = floatLimits(min=1.0, max=10.0)

  LevelOutlineWidthFactorLimits*     = floatLimits(min=0.0, max=1.0)
  LevelShadowInnerWidthFactorLimits* = floatLimits(min=0.0, max=1.0)
  LevelShadowOuterWidthFactorLimits* = floatLimits(min=0.0, max=1.0)

  AlphaLimits* = floatLimits(min=0.0, max=1.0)


proc loadTheme*(filename: string): ThemeStyle =
  var cfg = loadConfig(filename)
  result = parseTheme(cfg)

  # TODO these checks could be generated by the macro
  with result.ui.dialog:
    cornerRadius     = cornerRadius.limit(UiDialogCornerRadiusLimits)
    outerBorderWidth = outerBorderWidth.limit(UiDialogOuterBorderWidthLimits)
    innerBorderWidth = innerBorderWidth.limit(UiDialogInnerBorderWidthLimits)
    shadowXOffset    = shadowXOffset.limit(UiDialogShadowXOffsetLimits)
    shadowYOffset    = shadowYOffset.limit(UiDialogShadowYOffsetLimits)
    shadowFeather    = shadowFeather.limit(UiDialogShadowFeatherLimits)

  with result.ui.widget:
    cornerRadius = cornerRadius.limit(UiWidgetCornerRadiusLimits)

  with result.ui.splashImage:
    shadowAlpha = shadowAlpha.limit(AlphaLimits)

  with result.level.backgroundHatch:
    width         = width.limit(LevelBackgroundHatchWidthLimits)
    spacingFactor = spacingFactor.limit(LevelBackgroundHatchSpacingFactorLimits)

  with result.level.outline:
    widthFactor = widthFactor.limit(LevelOutlineWidthFactorLimits)

  with result.level.shadow:
    innerWidthFactor = innerWidthFactor.limit(LevelShadowInnerWidthFactorLimits)
    outerWidthFactor = outerWidthFactor.limit(LevelShadowOuterWidthFactorLimits)


proc saveTheme*(config: HoconNode, filename: string) =
  config.write(newFileStream(filename, fmWrite))



proc limit(config: HoconNode, key: string, limits: FieldLimits) =
  var v = config.get(key)
  v.num = v.num.limit(limits)

proc getColorArray(cfg: HoconNode, key: string, colors: var openArray[Color]) =
  for i in 0..colors.high:
    colors[i] = cfg.getColorHocon(fmt"{key}.{i}")


proc toLevelStyle*(cfg: HoconNode): LevelStyle2 =
  alias(s, result)
  s = new LevelStyle2

  var p = "general."
  s.lineWidth                 = cfg.getEnum(p & "line-width", LineWidth)
  s.backgroundColor           = cfg.getColor(p & "background")
  s.cursorColor               = cfg.getColor(p & "cursor")
  s.cursorGuidesColor         = cfg.getColor(p & "cursor-guides")
  s.linkMarkerColor           = cfg.getColor(p & "link-marker")
  s.selectionColor            = cfg.getColor(p & "selection")
  s.trailColor                = cfg.getColor(p & "trail")
  s.pastePreviewColor         = cfg.getColor(p & "paste-preview")
  s.foregroundNormalColor     = cfg.getColor(p & "foreground.normal")
  s.foregroundLightColor      = cfg.getColor(p & "foreground.light")
  s.coordinatesNormalColor    = cfg.getColor(p & "coordinates.normal")
  s.coordinatesHighlightColor = cfg.getColor(p & "coordinates.highlight")
  s.regionBorderNormalColor   = cfg.getColor(p & "region-border.normal")
  s.regionBorderEmptyColor    = cfg.getColor(p & "region-border.empty")

  p = "background-hatch."
  s.backgroundHatchEnabled       = cfg.getBool(p & "enabled")
  s.backgroundHatchColor         = cfg.getColor(p & "color")
  s.backgroundHatchWidth         = cfg.getFloat(p & "width")
  s.backgroundHatchSpacingFactor = cfg.getFloat(p & "spacing-factor")

  p = "grid."
  s.gridBackgroundStyle     = cfg.getEnum(p & "background.style", GridStyle)
  s.gridBackgroundGridColor = cfg.getColor(p & "background.grid")
  s.gridFloorStyle          = cfg.getEnum(p & "floor.style", GridStyle)
  s.gridFloorGridColor      = cfg.getColor(p & "floor.grid")

  p = "outline."
  s.outlineStyle       = cfg.getEnum(p & "style", OutlineStyle)
  s.outlineFillStyle   = cfg.getEnum(p & "fill-style", OutlineFillStyle)
  s.outlineColor       = cfg.getColor(p & "color")
  s.outlineWidthFactor = cfg.getFloat(p & "width-factor")
  s.outlineOverscan    = cfg.getBool(p & "overscan")

  p = "shadow."
  s.shadowInnerColor        = cfg.getColor(p & "inner.color")
  s.shadowInnerWidthFactor  = cfg.getFloat(p & "inner.width-factor")
  s.shadowOuterColor        = cfg.getColor(p & "outer.color")
  s.shadowOuterWidthFactor  = cfg.getFloat(p & "outer.width-factor")

  p = "floor."
  s.floorTransparent = cfg.getBool(p & "transparent")

  cfg.getColorArray(p & "background", s.floorBackgroundColor)

  p = "note."
  s.noteMarkerColor     = cfg.getColor(p & "marker")
  s.noteCommentColor    = cfg.getColor(p & "comment")
  s.noteBackgroundShape = cfg.getEnum(p & "background-shape", NoteBackgroundShape)

  cfg.getColorArray(p & "index-background", s.noteIndexBackgroundColor)

  s.noteIndexColor             = cfg.getColor(p & "index")
  s.noteTooltipBackgroundColor = cfg.getColor(p & "tooltip.background")
  s.noteTooltipTextColor       = cfg.getColor(p & "tooltip.text")

  cfg.getColorArray("label.text", s.labelTextColor)


proc toWindowStyle*(cfg: HoconNode): WindowStyle =
  alias(s, result)
  s = new WindowStyle

  s.modifiedFlagColor            = cfg.getColor("modified-flag")
  s.backgroundColor              = cfg.getColor("background.color")
  s.backgroundImage              = cfg.getString("background.image")
  s.titleBackgroundColor         = cfg.getColor("title.background.normal")
  s.titleBackgroundInactiveColor = cfg.getColor("title.background.inactive")
  s.titleColor                   = cfg.getColor("title.text.normal")
  s.titleInactiveColor           = cfg.getColor("title.text.inactive")
  s.buttonColor                  = cfg.getColor("button.normal")
  s.buttonHoverColor             = cfg.getColor("button.hover")
  s.buttonDownColor              = cfg.getColor("button.down")


proc toStatusBarStyle*(cfg: HoconNode): StatusBarStyle =
  alias(s, result)
  s = new StatusBarStyle

  s.backgroundColor        = cfg.getColor("background")
  s.textColor              = cfg.getColor("text")
  s.coordinatesColor       = cfg.getColor("coordinates")
  s.commandBackgroundColor = cfg.getColor("command.background")
  s.commandTextColor       = cfg.getColor("command.text")


proc toNotesPaneStyle*(cfg: HoconNode): NotesPaneStyle =
  alias(s, result)
  s = new NotesPaneStyle

  s.textColor      = cfg.getColor("text")
  s.scrollBarColor = cfg.getColor("scroll-bar")
  s.indexColor     = cfg.getColor("index")

  cfg.getColorArray("index-background", s.indexBackgroundColor)


proc toToolbarPaneStyle*(cfg: HoconNode): ToolbarPaneStyle =
  alias(s, result)
  s = new ToolbarPaneStyle

  s.buttonNormalColor = cfg.getColor("button.normal")
  s.buttonHoverColor  = cfg.getColor("button.hover")


proc loadThemeHocon*(filename: string): HoconNode =
  var p = initHoconParser(newFileStream(filename))
  let cfg = p.parse()

  cfg.limit("ui.dialog.corner-radius",      UiDialogCornerRadiusLimits)
  cfg.limit("ui.dialog.outer-border.width", UiDialogOuterBorderWidthLimits)
  cfg.limit("ui.dialog.inner-border.width", UiDialogInnerBorderWidthLimits)
  cfg.limit("ui.dialog.shadow.feather",     UiDialogShadowFeatherLimits)
  cfg.limit("ui.dialog.shadow.x-offset",    UiDialogShadowXOffsetLimits)
  cfg.limit("ui.dialog.shadow.y-offset",    UiDialogShadowYOffsetLimits)

  cfg.limit("ui.widget.corner-radius", UiWidgetCornerRadiusLimits)

  cfg.limit("ui.splash-image.shadow-alpha", AlphaLimits)

  cfg.limit("level.background-hatch.width",          LevelBackgroundHatchWidthLimits)
  cfg.limit("level.background-hatch.spacing-factor", LevelBackgroundHatchSpacingFactorLimits)

  cfg.limit("level.outline.width-factor", LevelOutlineWidthFactorLimits)

  cfg.limit("level.shadow.inner.width-factor", LevelShadowInnerWidthFactorLimits)
  cfg.limit("level.shadow.outer.width-factor", LevelShadowOuterWidthFactorLimits)

  result = cfg

