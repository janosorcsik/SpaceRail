# SpaceRail — átdolgozási terv

**Állapot:** 2026-09-21. Döntések lezárva, implementáció előtt. Az `ISSUES.md` a jelenlegi kód hibáit tartalmazza; ez a dokumentum azt, hogy **mi lesz helyette**. Ahol a két doksi ellentmond, ez a mérvadó — az `ISSUES.md`-ben az elévült pontok meg vannak jelölve.

**Referenciák:** `/Users/janosorcsik/Developer/mycast` (Platform réteg, egy az egyben átvehető fájlok), `/Users/janosorcsik/Developer/cosmos` (`AXClient.swift` — AX-recept), `/Users/janosorcsik/Developer/winmux` (`MacApp.swift` — fókusz-recept).

---

## Tartalom

- [Mit csinál az app](#mit-csinál-az-app)
- [Döntések](#döntések)
- [Modell](#modell)
- [Motor — WorkspaceEngine](#motor--workspaceengine)
- [Bevitel](#bevitel)
- [HUD](#hud)
- [Settings](#settings)
- [Konfiguráció](#konfiguráció)
- [Sorrend](#sorrend)
- [Feltevések](#feltevések)
- [Ahol a leggyengébb a bizonyíték](#ahol-a-leggyengébb-a-bizonyíték)
- [Későbbre](#későbbre)

---

## Mit csinál az app

Virtuális workspace-ek, amik között gyorsan lehet váltani, mert a macOS Spaces lassú. Egy workspace **ablakok halmaza** (nem appoké — egy appnak több ablaka lehet különböző workspace-eken). A váltás annyit tesz, hogy a workspace ablakait előrehozza, a mentett helyükre teszi, és a legutóbb használtat fókuszálja. **Semmi mást nem bánt:** nem rejt el, nem parkol képernyőn kívülre, nem minimalizál. Ami nincs a workspace-en, az ott marad, ahol volt — mögötte.

Ez a modell tudatosan más, mint a FlashSpace (app-szintű `hide()`, lassú, Finder-bugok) és az AeroSpace/yabai (off-screen parkolás, elárvult ablakok ha az ablakkezelő kilép). Nincs mit visszaállítani, ha az app meghal, mert soha nem vitt el semmit sehova.

---

## Döntések

Ezek a beszélgetésben lezárt kérdések; nem nyitjuk újra, csak ha a prototípus (0. lépés) megbuktatja.

| # | Kérdés | Döntés |
|---|---|---|
| D1 | Társítás egysége | **Ablak**, nem app. A frontmost app AX-fókuszált ablaka. |
| D2 | Elrejtés mechanizmusa | **Nincs.** Váltás = előrehozás + frame-visszaállítás. Más workspace ablakai a háttérben maradnak, láthatóan. |
| D3 | Nem társított ablakok | Nem bántjuk. Mindenhol látszanak, a workspace ablakai fölé kerülnek. |
| D4 | Cmd+tab / Dock-kattintás másik workspace ablakára | **Auto-váltás** arra a workspace-re. Nem társított ablaknál semmi. |
| D5 | Frame | Társításkor és **minden elváltáskor** mentjük; váltáskor visszaállítjuk. "Ahogy hagytad." Nincs folyamatos mozgás-figyelés. |
| D6 | Reboot / app kilépés | Ablak-ID-k elvesznek → **app-szintű, egyszer használatos szabály**: az app első ablakának megjelenésekor az összes ablaka a (legkisebb sorszámú) workspace-be kerül, a mentett frame-ek sorrendben, best-effort rájuk. Szabály törlődik. |
| D7 | Több monitor | Nem támogatott külön. Egy globális workspace-készlet. Mentett frame, ami nem esik képernyőre → fő képernyőre igazítva. |
| D8 | Billentyűk | Alapértelmezés: **⌃⌥⌘+1..9** váltás, **⌃⌥⌘⇧+1..9** társítás/leválasztás, **⌃⌥⌘+0** HUD ki/be. Mind átállítható a Settingsben. Hogy a ⌃⌥⌘-ot mi állítja elő (Caps Lock remap, Karabiner, kézzel), az az appon kívül van. |
| D9 | Settings ablak | **V1-ben.** Shortcut-szerkesztő (KeyboardShortcuts `Recorder`), launch at login. Semmi más. |
| D10 | HUD tartalma | Csak app-ikon, ablakonként. Nincs cím, nincs ablak-előnézet (screen recording engedélyt nem kérünk). |
| D12 | HUD megjelenítés | **Saját shortcut, toggle**, alapból **2 s után magától eltűnik** (Settings: Never / 1 / 2 / 3 / 5 s). Minden hotkey-akció újraindítja a számlálót. Nincs modifier-tartás figyelés — így nincs event tap, nincs global monitor. |
| D13 | Hotkey mechanizmus | **`sindresorhus/KeyboardShortcuts`** (Carbon `RegisterEventHotKey`), `exactVersion` pin. A mycast `KeyboardTap`/`KeyChord` **nem** kerül át. |
| D14 | Workspace-lista | **Dinamikus**: 3-mal indul, Settingsben ⊕/⊖. Az ID-k sosem kerülnek újrafelhasználásra (tárolt shortcut ne szivárogjon át). Új workspace default shortcutja a pozíciója szerinti szám (1–9), ha van. Törléskor a shortcutja törlődik, az ablakai szabadok lesznek. |
| D15 | Workspace-név | Szerkeszthető a Settings táblázatában, a HUD és a menü ezt mutatja. Alapból a pozíció száma. |
| D16 | HIG | Settings: toolbar-tabok (General / Workspaces), `Table` + ⊕/⊖ `ControlGroup` a lista alatt (kijelölés-alapú), fix méret. Menü: `Toggle` pipa, a hotkey megjelenítve a menüelemen (csak kijelzés — a Carbon hotkey fut). |
| D11 | Appon belüli ablakváltás (cmd+`) követése | **V1-ben nem.** AXObserver-t igényel appokként; az app-szintű aktiválás lefedi a gyakori eseteket. Lásd Későbbre. |

---

## Modell

```swift
struct WindowSlot: Codable {
    var windowID: CGWindowID      // _AXUIElementGetWindow — az ablak életéig stabil, túléli a SpaceRail újraindítását
    var bundleID: String
    var frame: CGRect             // AX koordináta (top-left origin)
}

struct Workspace: Codable {
    var id: Int                   // 1...9
    var windows: [WindowSlot]     // MRU sorrend: első = legutóbb fókuszált
}

struct State: Codable {
    var workspaces: [Workspace]
    var selectedID: Int
    var pendingApps: [String: Int]   // bundleID → workspaceID, D6 szabályok
}
```

Perzisztencia: JSON, `~/Library/Application Support/<AppProfile.dataDirectoryName>/state.json`. Írás minden állapotváltozásnál (a fájl kicsi, nem éri meg debounce-olni). Az `AppProfile` az `ISSUES.md` Gyors nyereségek 2.2 szerint — dev build más mappába ír.

Ablak-azonosítás: `_AXUIElementGetWindow(AXUIElement, &CGWindowID)`. Privát, de minden ablakkezelő ezt használja (Cosmos `AXClient.swift:295`, winmux `accessibility.swift:359`, AltTab, Hammerspoon). Deklaráció:

```swift
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
```

---

## Motor — WorkspaceEngine

Egyetlen osztály, a mai `WorkspaceService` helyén. Nem singleton-kényszer, de v1-ben lehet az.

### Váltás N-re

```
1. snapshot(current)
     az aktuális workspace minden ablakára: frame lekérés → WindowSlot.frame frissítés
     (AX-hibát adó ablak = bezárt → kiesik a halmazból)

2. for app in N appjai, fordított MRU sorrendben (utolsó = az MRU-első ablak appja):
       for window in app ablakai N-ben, fordított MRU:
           if !isFullScreen(window) && frame != slot.frame: setFrame(slot.frame)
           kAXMainAttribute = true
           kAXRaiseAction                       // appon BELÜL rendez — lásd lent
       app.activate()                           // main + key ablakot hozza előre, a többit NEM

3. selectedID = N, mentés
```

**Miért így, és nem "raise mindent, activate egyet":** a `kAXRaiseAction` doksija szerint az ablak *"as frontmost as is allowed by the containing application's circumstances"* lesz — azaz csak az **appon belül** kerül tetejére, más appok ablakai fölé nem. A Cosmos (`AXClient.swift:170-177`) és a winmux (`MacApp.swift:211-217`) is ezért párosítja mindig `activate()`-tel. Az `activate()` alapból csak a main és key ablakot hozza előre (`.activateAllWindows` nélkül), ezért az app **nem társított** ablakai hátul maradnak — ez kell a D3-hoz.

> **Mérés után javítva (2026-09-21):** a fenti sorrend (raise → activate) **egyablakos** appra jó, többablakosra nem: az activate csak a main ablakot hozta a Finder fölé, a másodikat nem. A helyes sorrend: **`activate()` → megvárni, míg `isActive` (max 300 ms, 20 ms-os poll) → raise ablakonként (MRU fordítva)**. Aktív appon a raise már globálisan előre hoz. Mérve: 3 ablak / 2 app, Finder közéékelve → mind felül, MRU-sorrend, frame-ek visszaállítva, **~90 ms**. A 0. lépés ezzel go.
>
> **Másik csapda:** `CGWindowListCreateDescriptionFromArray` Swiftből üres tömböt ad (nyers pointer-CFArray-t vár, nem CFNumber-t). Helyette egyetlen `CGWindowListCopyWindowInfo(.optionAll)` hívásból épül `windowID → pid` tábla, és appokként egyszer enumerálunk (`AXWindow.find(ids:)`).

Következmény: a váltás annyi app-aktiválás, ahány app van a workspace-en. Ez a mérendő szám, lásd Ahol a leggyengébb a bizonyíték.

`setFrame` recept (Cosmos `AXClient.swift:150-156`): size → position → size, mert AX-ben nincs atomi frame-setter és a sorrend számít képernyőhatáron.

### Társítás / leválasztás (⌃⌥⌘⇧+N)

```
window = frontmost app AX-fókuszált ablaka
guard isManageable(window)                     // lásd lent
id = windowID(window)

if N tartalmazza id-t:      eltávolít N-ből                             // leválasztás
else:                        eltávolít minden workspace-ből, N elejére beszúr (MRU-első), frame = aktuális
mentés
```

Az ablak nem mozdul, nem tűnik el. A HUD frissül.

`isManageable` (Cosmos `AXClient.swift:224-246`): role == `kAXWindowRole`, nem `kAXModal`, subrole != `kAXSystemDialogSubrole`, standard subrole **vagy** van close/minimize/zoom/fullscreen gombja, `kAXPositionAttribute` settable. Ha nem manageable → `NSSound.beep()`.

### Fókuszkövetés (D4 + MRU)

`NSWorkspace.didActivateApplicationNotification` → az aktivált app AX-fókuszált ablaka → `windowID`:

- ha az aktuális workspace-en van → MRU elejére
- ha **másik** workspace-en van → váltás oda (a teljes váltás-algoritmus, tehát a workspace többi ablaka is előrejön)
- ha sehol → semmi

Vigyázat a visszacsatolásra: a saját `activate()` hívásaink is kiváltják ezt a notificationt. Egy `isSwitching` flag alatt a handler ne csináljon semmit.

### App-életciklus (D6)

- `didTerminateApplicationNotification` → az app minden ablaka kikerül a workspace-ekből; ha volt bárhol → `pendingApps[bundleID] = legkisebb workspaceID` ahol volt. A frame-ek megmaradnak a szabály mellett (sorrendben), hogy best-effort vissza tudjuk tenni.
- `didLaunchApplicationNotification` → ha van `pendingApps[bundleID]`: az app ablakai még nem biztos, hogy léteznek. Rövid poll (0.5 s, max ~10 s), amíg `kAXWindowsAttribute` nem üres → minden manageable ablak a workspace-be, mentett frame-ek sorrendben ahány jut. Szabály törlődik.
- Induláskor: `state.json` betöltés → minden `WindowSlot`-ra ellenőrzés, létezik-e még az ablak (`CGWindowListCopyWindowInfo` ID-k). Ami nem létezik → D6 szerint pending szabállyá alakul. Ami létezik → marad (SpaceRail újraindítása nem veszít semmit, amíg az appok futnak).

---

## Bevitel

**`sindresorhus/KeyboardShortcuts`** (3.x, `exactVersion`). Carbon `RegisterEventHotKey`: a rendszer natívan elnyeli a kombinációt, a cél app nem kapja meg, nincs beep, nincs key repeat, nincs árva keyUp. Nincs event tap → a tap-letiltás hibaosztály (`ISSUES.md` P0/2) nem kezelve, hanem **nem létezik**. Secure Input alatt is működik. A CGEventSupervisor kikerül.

```swift
extension KeyboardShortcuts.Name {
    static func switchTo(_ n: Int) -> Self {
        Self("switch-\(n)", default: .init(digit(n), modifiers: [.control, .option, .command]))
    }
    static func toggle(_ n: Int) -> Self {
        Self("toggle-\(n)", default: .init(digit(n), modifiers: [.control, .option, .command, .shift]))
    }
    static let showHUD = Self("show-hud", default: .init(.zero, modifiers: [.control, .option, .command]))
}

// induláskor, engedély megléte után:
for n in 1...9 {
    KeyboardShortcuts.onKeyDown(for: .switchTo(n)) { engine.switch(to: n) }
    KeyboardShortcuts.onKeyDown(for: .toggle(n))   { engine.toggle(workspace: n) }
}
KeyboardShortcuts.onKeyDown(for: .showHUD) { panel.toggle() }
```

A shortcutok tárolása a könyvtár dolga (UserDefaults, `Name` kulccsal) — a `State` nem tartalmaz billentyűt. A handlerek a main run loopon futnak, nincs callback-latency kérdés.

**Miért nem a mycast `KeyboardTap`:** az `ISSUES.md` M1 érve a modifier-tartás (HUD hold) és a jövőbeli modifier-only chord volt. D12 szerint nincs hold, D8 szerint a ⌃⌥⌘ előállítása külső — így a tap egyetlen előnye sem marad, a hátrányai (Accessibility-függő tap, letiltás-kezelés, callback-tehermentesítés) igen.

---

## HUD

Meglévő `FloatingPanel`, az `ISSUES.md` P1/4, 7, 10 javításaival (M5):

```swift
level = .statusBar
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
isReleasedWhenClosed = false
hidesOnDeactivate = false
ignoresMouseEvents = true
```

Megjelenítés (D12): a `showHUD` shortcut **toggle**. Látható marad váltás és társítás közben is (így látszik az eredmény), csak a shortcut újranyomása rejti el. Nem interaktív, `ignoresMouseEvents = true`. Élőben frissül a modellből (`@Observable`).

Tartalom: workspace-ek **sorokban** (függőleges lista), soronként a workspace száma + az ablakok app-ikonjai MRU sorrendben, wrappal ha nem fér ki. Csak a **nem üres** workspace-ek és az aktuális látszanak. Az aktuális kiemelve.

Ez az egyetlen rész, amit vázlaton kell látni, nem előre eldönteni. V1: a lehető legegyszerűbb, utána iteráció.

Ikonok: `AppIconService` az `ISSUES.md` Main thread fejezete szerint — `cached()` a body-ban, `prefetch()` társításkor és `didLaunchApplication`-nél. A tap-latency érv megszűnt (nincs tap), de a body-ban diszk-I/O továbbra sem oké.

---

## Settings

SwiftUI `Settings { }` scene a `MenuBarExtra` mellett; a menüből `SettingsLink`-kel nyílik. LSUIElement app ablakához `NSApp.activate(ignoringOtherApps: true)` kell a megnyitás előtt, különben más ablakok mögé kerül (`ISSUES.md` P1/5a mintája).

Tartalom, ennyi és nem több:

```
Shortcuts
  Workspace 1    Switch: [⌃⌥⌘1]    Assign/unassign: [⌃⌥⌘⇧1]
  ...
  Workspace 9    Switch: [⌃⌥⌘9]    Assign/unassign: [⌃⌥⌘⇧9]
  Show HUD       [⌃⌥⌘0]
General
  [ ] Launch at login                 — SMAppService.mainApp.register() / unregister()
```

Minden mező `KeyboardShortcuts.Recorder`, ami maga tárol, maga jelez ütközést, és a `Reset` is a könyvtár dolga. A Settingsnek nincs saját modellje.

---

## Konfiguráció

Az `ISSUES.md` P0/1, P1/5, P1/10 szerint:

- `ENABLE_APP_SANDBOX = NO`, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, template-maradványok ki
- `INFOPLIST_KEY_LSUIElement = YES`, `setActivationPolicy` hívások törlése
- **`Platform/Permissions.swift`** a mycast-ból (M3): `AXIsProcessTrustedWithOptions(prompt: true)` induláskor, majd 1 s poll `prompt: false`-szal, amíg `true` → engine indul. Nincs `runModal()`, nincs `terminate()`. A hotkey-ek regisztrálása nem függ az engedélytől (Carbon), de a handlerük engedély nélkül csak beepel.
- **SPM:** `KeyboardShortcuts` `exactVersion`-nel. Nincs más dependency.
- `os.Logger` (`ISSUES.md` P2/19)
- `AppProfile` (`ISSUES.md` 2.2): dev build külön bundle ID, külön state mappa

---

## Sorrend

| # | Lépés | Mit dönt el | Becslés |
|---|---|---|---|
| **0** | **Prototípus.** Egy `swift` script vagy playground: 3 futó app, 2–2 ablak, egy másik app ablaka közéjük ékelve. `setFrame` + main + raise + `activate` a fenti algoritmussal, `CFAbsoluteTimeGetCurrent` mérés. | **Go/no-go.** (a) Előrejön-e ugyanannak az appnak mindkét ablaka, vagy csak a main? (b) Teljes váltás < 100 ms? | fél nap |
| 1 | Konfig + CGEventSupervisor → KeyboardShortcuts, HUD toggle shortcutra. A régi app-szintű logika még fut. `PanelService`, `WorkspaceKey` törlése. | P0 mind, D12, D13 | fél nap |
| 2 | Modell + `WorkspaceEngine` (váltás, társítás) + JSON perzisztencia. `WorkspaceService` törlése. | a lényeg | 2 nap |
| 3 | Fókuszkövetés (D4), app-életciklus + pending szabály (D6), induláskori reconcile. | a többi döntés | 1 nap |
| 4 | HUD sorokra, ikon ablakonként, prefetch. Vázlat → iteráció. | D10 | 1 nap + iteráció |
| 5 | Settings: `Recorder` mezők + launch at login. | D9 | fél nap |

A 0. lépés eredménye módosíthatja a 2.-at (ha (a) nem: appokként több raise+activate kör; ha (b) nem: frame-visszaállítás a raise után, háttérben).

---

## Feltevések

Amit nem kérdeztünk meg, mert egyértelműnek tűnt. Ha valamelyik rossz, itt kell módosítani.

- **Minden ablak ugyanazon a macOS Space-en van.** Ha egy társított ablak másik natív Space-en volna, az `activate()` odaugrik (lassú). A `kAXWindowsAttribute` csak az aktuális Space ablakait adja, tehát a másik Space-en lévő ablak "halottnak" látszik és kiesik.
- **Natív fullscreen ablak** társítható, de `setFrame`-et nem hívunk rá (`kAXFullScreenAttribute == true`); a raise+activate elég.
- **Pending szabály** a legkisebb workspace-ID-t választja, ha az app több helyen volt.
- **9 workspace** a billentyűk miatt; a HUD csak a nem üreseket + az aktuálisat mutatja.
- **Frame-mentés nem folyamatos**: csak társításkor és elváltáskor. Ha a user mozgat egy ablakot és a SpaceRail közben crashel, az utolsó elváltás állapota marad meg. Elfogadható.
- **Saját `activate()` visszacsatolás** `isSwitching` flaggel kiszűrve.
- **`_AXUIElementGetWindow`** privát API; ha egy macOS-verzió eltörné, az ablak-azonosítás fallbackje `CGWindowListCopyWindowInfo` + AX pozíció/méret egyezés. Nem építjük meg előre.

---

## Ahol a leggyengébb a bizonyíték

A 0. lépés két kérdése. Egyiket sem lehet doksiból eldönteni, csak a gépen.

1. **Ugyanannak az appnak több ablaka.** Az `activate()` a main + key ablakot hozza előre. Ha a workspace-en két VS Code ablak van, a raise az appon belül mindkettőt tetejére teszi, de hogy az activate után a **második** is más appok ablakai fölé kerül-e, arra nincs egyértelmű forrás. A Cosmos és a winmux egyetlen ablakot fókuszál, nem kettőt. Ha nem: appokként ablakonként `main + raise + activate` — több app-switch, de működik.

2. **Váltás sebessége.** Egy `activate()` ~10–30 ms, menü bar átvált mindegyiknél. 3 app × 2 ablak esetén 3 aktiválás + 6 `setFrame` (AX setPosition/setSize appokként 5–30 ms, Electron lassabb). Ha a teljes váltás > 100 ms, a frame-visszaállítást a raise **után**, aszinkron kell futtatni, hogy a fókusz azonnal átmenjen és a mozgás "utánajöjjön".

---

## Későbbre

Nem v1, de a modell úgy készül, hogy ezek ráépülhessenek.

- **AXObserver appokként** `kAXFocusedWindowChangedNotification`-re (D11): cmd+` ugyanazon app másik workspace-ablakára → auto-váltás; MRU pontosabb. Cosmos `AXApplicationObserverRegistry.swift` másolható (~80 sor + lifecycle).
- **Settings bővítés:** workspace-ek átnevezése (a HUD-on név a szám mellett), HUD auto-hide időzítő, workspace-szám korlátozása.
- **"x" a HUD ikonján** leválasztáshoz — ehhez `ignoresMouseEvents = false` kell a HUD-on, és a HUD-nak interaktívvá kell válnia. A toggle-alapú megjelenés (D12) ezt már **nem** zárja ki, ez a hold elvetésének mellékhaszna.
- **Secure Input jelzés** a HUD-on (`ISSUES.md` W2).
- **Ablak-cím a HUD-on** ha az ikon nem elég megkülönböztetni két ablakot ugyanabból az appból.
