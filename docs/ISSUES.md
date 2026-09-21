# SpaceRail — ismert hibák, megoldási ötletek, teendők

**Állapot:** 2026-09-03, commit `1ae198c`. Build: `xcodebuild -target SpaceRail -arch arm64` → BUILD SUCCEEDED, 0 warning. Minden alábbi hiba futásidejű vagy konfigurációs, nem fordítási.

**Referencia projekt:** `/Users/janosorcsik/Developer/cosmos` — érett AppKit window manager (126 commit, ~19k sor, teljes CI/release pipeline). Ahol a Cosmos már megoldott egy itt is jelentkező problémát, a mintát idézzük. Nem cargo-kultusz: egy 439 soros hobbi projektre nem húzunk rá notarizált Homebrew pipeline-t (lásd a „Szándékosan nem veszünk át" fejezetet).

**Ez a dokumentum összevonja:** a korábbi `COSMOS_ADOPTION_NOTES.md`-t, a `docs/icon-prefetch-proposal.md`-t és a 2026-09-03-i kódátnézés két körét. A régi fájlok törölve.

> **2026-09-21 — átdolgozás.** Az app ablak-szintű, elrejtés nélküli modellre áll át, lásd **[`PLAN.md`](PLAN.md)**. Ez a dokumentum a *jelenlegi* kód hibáit írja le; ahol a PLAN mást mond, a PLAN a mérvadó. Az elévült pontok `~~ELÉVÜLT~~` jelöléssel maradnak itt, indoklással, hogy látszódjon, miért nem kell megcsinálni. Ami nincs megjelölve, az az átdolgozás után is érvényes (konfig, tap, panel, permission flow, main thread, infrastruktúra).

---

## Tartalom

- [P0 — Égető](#p0--égető)
- [P1 — Funkcionális hibák](#p1--funkcionális-hibák)
- [P2 — Kisebb hibák](#p2--kisebb-hibák)
- [Main thread tehermentesítés (Hashimoto-elv)](#main-thread-tehermentesítés-hashimoto-elv)
- [Design-kérdések](#design-kérdések)
- [Gyors nyereségek](#gyors-nyereségek)
- [Infrastruktúra](#infrastruktúra)
- [Architektúra (távlati)](#architektúra-távlati)
- [Átvehető a mycast-ból](#átvehető-a-mycast-ból)
- [Ötletek a winmux-ból](#ötletek-a-winmux-ból)
- [Szándékosan nem veszünk át](#szándékosan-nem-veszünk-át)
- [Javasolt sorrend](#javasolt-sorrend)

---

## P0 — Égető

Ezek nélkül az app vagy egyáltalán nem indul aláírt buildben, vagy futás közben némán meghal.

### 1. App Sandbox be van kapcsolva

**Hol:** `SpaceRail.xcodeproj/project.pbxproj` — `ENABLE_APP_SANDBOX = YES` mindkét konfigurációban. Nincs külön `.entitlements` fájl, a Xcode automatikusan generálja a `com.apple.security.app-sandbox` entitlementet.

**Tünet:** Aláírt buildben az `AXIsProcessTrusted()` mindig `false` → az app a „Accessibility Permission Required" alertet mutatja és kilép. Ha jelenleg működik, az azért van, mert a Xcode Debug futtatás vagy egy régebbi, sandbox nélkül aláírt binárisra adott TCC-engedély élteti.

**Miért:** Sandboxolt processz nem kaphat Accessibility trustot, nem tehet fel `CGEventTap`-et (a CGEventSupervisor ezt igényli), és nem hívhat `hide()`/`unhide()`-ot más appokra. Az app teljes funkcionalitása sandbox-ellenes.

**Megoldás (Cosmos-minta):**
- `ENABLE_APP_SANDBOX = NO`
- `ENABLE_HARDENED_RUNTIME = YES` (Cosmos: csak Release-ben; itt mindkettőben maradhat)
- `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` — üres entitlement set, ne kerüljön be a `get-task-allow` sem Release-be
- Template-maradványok kidobása: `REGISTER_APP_GROUPS`, `ENABLE_USER_SELECTED_FILES`
- A Cosmos ezenfelül `CODE_SIGN_STYLE = Manual` + `Developer ID Application`-t használ Release-re — ez csak akkor kell, ha terjeszteni akarod

**Ellenőrzés:** `codesign -d --entitlements - SpaceRail.app` → nem szerepelhet `app-sandbox`. `codesign -dvvv` → `Runtime Version=` sor jelen van (hardened runtime).

---

### 2. Az event tap letiltódik és soha nem áll vissza

> **PLAN D13:** nem javítjuk, hanem **megszüntetjük a tapet**. Carbon hotkey-ekkel ez a hibaosztály nem létezik. A lenti elemzés a döntés indoklásához marad.

**Hol:** `CGEventSupervisor+Setup.swift:21-28` (dependency), `CGEventSupervisor+Callback.swift:15-57` (dependency), `PanelService.swift:24-34` (saját).

**Tünet:** Egy idő után — gyakran az első ctrl+opt lenyomásnál hideg cache-en — a HUD nem jelenik meg, a ctrl+opt+1..4 nem vált. Nincs hibaüzenet, a menü bar ikon él, az app fut. Csak újraindítás segít.

**Miért, két összetevő:**

1. **A könyvtár nem kezeli a tap-letiltást.** A CGEventSupervisor `.defaultTap`-pal (aktív tap) hoz létre tapet. A macOS aktív tapet letilt, ha a callback túl sokáig fut (`kCGEventTapDisabledByTimeout`), vagy ha Secure Input indul (`kCGEventTapDisabledByUserInput`, pl. jelszómező). Ilyenkor a rendszer küld egy ilyen típusú eseményt, és a callbacknek kell `CGEvent.tapEnable(tap:enable:true)`-t hívnia. A könyvtár callbackjében erre nincs ág — ellenőrizve a checkoutban.

2. **A saját callback lassú.** A tap callback a rendszer *teljes* eseményfolyamát blokkolja, amíg fut. `PanelService.handleFlagsChanged` ebben végzi: `runningApplications` bejárás → `removeClosedApps()` → `showPanel()` (setFrame + orderFront) → SwiftUI render → `AppIconsView.body` → `AppIconService.get()` → hideg cache-en appokként `urlForApplication(withBundleIdentifier:)` (Launch Services) + `icon(forFile:)` (diszk I/O). Több app esetén ez könnyen túllépi a küszöböt.

**Megoldás A — tap újraengedélyezés (Cosmos-minta, `ModifierFlagsMonitor.swift:64-76`):**

A Cosmos saját, ~60 soros tap wrappert használ, benne a re-enable ággal:

```swift
func handle(type: CGEventType, event: CGEvent) {
    switch type {
    case .flagsChanged:
        publishModifiers(event.flags)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        publishModifiers(currentModifierFlags())   // ← állapot újraszinkron, mert eseményeket vesztettünk
    default:
        break
    }
}
```

Ide két út:
- **CGEventSupervisor elhagyása**, saját wrapper a Cosmos mintájára. A projekt a könyvtárból csak `flagsChanged` + `keyDown` feliratkozást használ; a `NSEvent` konverzió, a névvel feliratkozás, a `cancel()` associated-object mechanizmus mind felesleges. Saját wrapperrel a 3. pont (dependency pin) is megszűnik.
- **Fork/PR** a könyvtárba: a callback elején a két disabled típus kezelése + a maszkba felvenni őket.

Cosmos-részlet, ami itt is hasznos: a modifier-figyelő tap `.listenOnly`, csak a keyDown-cancel-elő tap `.defaultTap`. A listenOnly tapet nem tiltja le a timeout. Érdemes **két tapet** használni: egy listenOnly a flagsChanged-re (HUD megjelenítés), egy defaultTap a keyDown-ra (cancel kell). Vagy — ha a rendszer beep elviselhető lenne — egyetlen listenOnly, de a README szerint a beep-et pont ezért javítottad, tehát a keyDown-hoz kell a defaultTap.

**Megoldás B — callback tehermentesítés:** lásd a [Main thread tehermentesítés](#main-thread-tehermentesítés-hashimoto-elv) fejezetet. Röviden: a callback csak állapotot állít és azonnal visszatér; a tényleges munka (`DispatchQueue.main.async` / `Task { @MainActor }`) a következő run loop-körön fut; az ikonok már előre a cache-ben vannak.

**Ellenőrzés:** Kényszerített teszt: `Thread.sleep(forTimeInterval: 2)` a callbackbe → egy billentyű → sleep kivétele → a következő lenyomásra a tapnek automatikusan vissza kell állnia. Secure Input teszt: Keychain Access-ben jelszómezőbe kattintás, kilépés, hotkey.

---

### 3. A CGEventSupervisor `branch = main`-re van kötve

**Hol:** `project.pbxproj:351-352` (`kind = branch; branch = main`). `Package.resolved` `d20d7aa8e008a1cc8dd2e26b027118a0fcfc2f96`-ot rögzít.

**Miért baj:** Egy `File → Update Packages` tetszőleges upstream kódot behúz egy olyan processzbe, aminek globális billentyűzet-tap joga és Accessibility engedélye van. Supply-chain szempontból ez a legrosszabb kombináció.

**Megoldás:**
- Ha van tag az upstreamben: `kind = exactVersion` vagy `upToNextMinorVersion`. Cosmos a `from:` mintát használja (`Yams from: "6.2.2"`), de az ő esetükben ez egy YAML parser, nem privilegizált eseményfigyelő — itt indokolt a szigorúbb pin.
- Ha nincs tag: `kind = revision`, `d20d7aa…`-ra fixálva.
- **Vagy** a 2. pont A megoldása (saját wrapper) — akkor nincs mit pinelni.

---

## P1 — Funkcionális hibák

Napi használatban zavaró, de az app nem hal meg tőlük.

### 4. Fullscreen appok fölött nem jelenik meg a HUD

**Hol:** `FloatingPanel.swift:20-22` — `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`.

**Tünet:** Fullscreen appban (Safari, VS Code, videó) ctrl+opt-ra semmi nem látszik. A váltás közben megtörténik — vakon.

**Miért:** Fullscreen space-be csak `.fullScreenAuxiliary` viselkedésű ablak léphet be. A `.floating` szint ráadásul a menü bar alatt van.

**Megoldás (Cosmos-minta, `SwitcherOverlayWindowController.swift:47-73`):**

```swift
window.level = .statusBar
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
window.hidesOnDeactivate = false
window.isReleasedWhenClosed = false
window.animationBehavior = .none
window.isOpaque = false
window.setAccessibilitySubrole(.unknown)   // ne jelenjen meg AX-fában ablakként
```

`.statusBar` szint a menü bar szintje — fullscreen fölé is megy. `.stationary` (ami most van) Exposé közben nem mozgatja az ablakot; HUD-nak nem kell, elhagyható.

---

### 5. Accessibility engedély flow

**Hol:** `SpaceRailApp.swift:23-45`.

Több hiba egyben:

**a) Az alert az ablakok mögé kerül.** `.accessory` policy mellett az app nem aktív; `runModal()` feldob egy ablakot, de a rendszer nem hozza előre. Első indításnál a user azt látja: „nem indul el semmi". Megoldás: `NSApp.activate(ignoringOtherApps: true)` az alert előtt (Cosmos `StatusMenuController.swift:35` ugyanezt teszi a menü megnyitásakor).

**b) `AXIsProcessTrusted()` nem prompt-ol.** A user megnyitja a Settings > Privacy > Accessibility-t, de az app nincs a listában — „+"-szal kell kikeresnie. Megoldás (Cosmos `AXClient.swift:67-71`):

```swift
func ensureAccessibilityPermission(prompt: Bool) -> Bool {
    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([promptKey: prompt] as CFDictionary)
}
```

`prompt: true` → a rendszer maga dobja fel a dialógust **és** felveszi az appot a listába kikapcsolt állapotban. A Cosmos indításkor `prompt: true`-val hív (`AccessibilityPermissionController.checkAtLaunch`), a Settings UI-ban `prompt: false`-szal pollol.

**c) `open` + `terminate` versenyhelyzet.** `NSWorkspace.shared.open(url)` aszinkron; az azonnali `terminate` néha megelőzi. Megoldás: ne lépjen ki az app — ehelyett **polloljon** (pl. 1 s-os `Timer`, `prompt: false`), és amikor `true` lesz, regisztrálja az event monitorokat. Így nem kell újraindítani engedélyezés után sem. Ez a leggyakoribb minta a kategóriában (Rectangle, AltTab, Hammerspoon mind így).

**d) Egyszeri check.** Ha futás közben visszavonják az engedélyt, a tap némán meghal (lásd 2. pont). A poll-alapú megoldás ezt is lefedi: ha `true` → `false`, tapet lebontja, alertet mutat.

**e) `init()`-ben blokkoló modal.** `runModal()` az `App.init()`-ben az egész scene felépülését blokkolja. A poll-megoldás ezt is megszünteti: az init csak elindítja a checket, a többi aszinkron.

**Cosmos System Settings URL** (`GeneralSettingsService.swift:82-90`): `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` — ugyanaz, mint a jelenlegi, ez rendben van.

---

### 6. Több monitor: rossz helyre kerül a HUD

**Hol:** `FloatingPanel.swift:29-40`.

**Tünet:** Külső monitoron dolgozva a panel a másik kijelzőn, rossz mérettel jelenik meg.

**Miért:** A méret `NSScreen.main` (= a fókuszált ablak képernyője) frame-jéből jön, a pozíció fixen `(0, 0)` — ami a **primary** képernyő bal alsó sarka a globális koordinátarendszerben. Ha a két képernyő nem azonos, méret és hely nem passzol.

**Megoldás:**
- Minimum: `screenFrame.origin` használata `(0, 0)` helyett.
- Jobb: melyik képernyőre kerüljön? Három ésszerű választás: a) ahol az egér van, b) ahol a fókuszált ablak van, c) mindegyikre egy-egy panel. A Cosmos az egérpozíciót használja fallbackkel (`SwitcherOverlayScreenLocator.swift`):

```swift
let mouseLocation = NSEvent.mouseLocation
return NSScreen.screens.first { $0.frame.contains(mouseLocation) }?.visibleFrame
    ?? NSScreen.main?.visibleFrame
    ?? NSScreen.screens.first?.visibleFrame
```

HUD-nál valószínűleg a **fókuszált app képernyője** a legjobb (oda nézel), de az egér-alapú egyszerűbb és a Cosmos-nál bevált.

- Képernyő-változás kezelése: `NSApplication.didChangeScreenParametersNotification` figyelése, hogy monitor le/felcsatlakozásra újraszámolja a frame-et — most minden `showPanel()`-nél újraolvassa, ami egyszerű és működik, csak felesleges munka a callbackben.

---

### 7. A panel elnyeli az egérkattintásokat

**Hol:** `FloatingPanel.swift` — nincs `ignoresMouseEvents`.

**Tünet:** Amíg a ctrl+opt-ot tartod, a teljes képernyőn nem tudsz kattintani. ctrl+opt+klikk kombók (pl. terminálban, IDE-ben) halottak.

**Megoldás:** `ignoresMouseEvents = true`. A HUD nem interaktív, nincs vesztenivaló. (A Cosmos `false`-ra állítja, de nála a switcher overlay kattintható — ott outside-click detektálás van külön tap-pel.)

Alternatíva: a panel ne legyen teljes képernyős, csak a HUD méretű, középre pozicionálva. Ez a kompozíciós költséget is csökkenti (jelenleg egy teljes képernyős átlátszó layer-backed ablakot rajzol a rendszer minden frame-ben, amíg látható). Ehhez a `NSHostingView.fittingSize`-t kell lekérdezni és a frame-et abból számolni.

---

### 8. ~~ELÉVÜLT~~ Váltás után nem kap fókuszt egyik app sem

> **Elévült:** a PLAN váltás-algoritmusa (`main + raise + activate` appokként, MRU sorrend) a fókuszt magától rendezi — nem külön javítás, hanem a motor része. Az alábbi elemzés a *miért*-hez még hasznos.

**Hol:** `WorkspaceService.swift:56-88`.

**Tünet:** Workspace-váltás után kattintani kell, mielőtt gépelni tudsz.

**Miért:** A frontmost app elrejtésekor a macOS a „következő látható" appnak adja a fókuszt — ami lehet Finder, vagy egy olyan app, amit egy pillanattal később rejtesz el. `activate()` sehol nincs.

**Megoldás:** A cél workspace **utoljára aktív** appját aktiválni a hide/unhide után. Ehhez a modellnek meg kell jegyeznie, melyik app volt utoljára frontmost az adott workspace-en (`NSWorkspace.didActivateApplicationNotification` figyelése, a Cosmos `WindowEventMonitor.swift:104-147` mintájára). Ha nincs ilyen, a lista első appja.

Cosmos-figyelmeztetés (`AXClient.swift:174-175`): `.regular` activation policy mellett az `activate()` nem adja át megbízhatóan a fókuszt; `.accessory`-nál működik. SpaceRail `.prohibited`/`.accessory` — rendben.

Sorrend: unhide → activate → hide. Ha előbb hide, a rendszer közben átdobja a fókuszt valahova, és az activate-nek küzdenie kell.

---

### 9. `focusedAppBundleIdentifier` elavul

**Hol:** `PanelService.swift:26`.

**Tünet:** ctrl+opt+1-el váltasz, majd ctrl+opt nyomva tartva shift+2 → nem azt az appot rendeli át, amit gondolsz.

**Miért:** A **shift lenyomása is flagsChanged**, tehát a `handleFlagsChanged` újra lefut és újra lekéri a frontmost appot — ami a 8. pont miatt már valami más (Finder, vagy a következő látható app).

**Megoldás:** A frontmost appot csak akkor rögzíteni, amikor az overlay **átmenete** történik (nem volt → van), nem minden flagsChanged-en. Egy `isOverlayActive` flag: ha `false → true`, rögzít + panel show; ha `true → false`, panel hide; ha `true → true` (pl. shift jött), semmi. Ez a 12. pont (redundáns hívások) egy részét is megoldja.

Továbbá: ha a user a HUD közben váltott workspace-t, a rögzített app rejtve van. Kérdés, hogy egy rejtett app átrendelése értelmes-e — valószínűleg igen (átrendezés kétlépéses használatban), csak legyen determinisztikus.

---

### 10. Activation policy hack + `hidesOnDeactivate`

**Hol:** `SpaceRailApp.swift:15-20`, `FloatingPanel.swift`.

**Miért törékeny:** `.accessory` → `checkForAccessibilityPermissions()` → `.prohibited`. A `.prohibited` dokumentáltan tiltja az ablakkészítést. Az egész működés azon múlik, hogy a `PanelService.shared` (és benne a `FloatingPanel`) a `registerEventMonitors()` hívásakor, tehát még a `.prohibited` *előtt* jön létre. Ha valaki átrendezi az initet, vagy lazy-vé teszi a panelt, elszáll. Plusz az induláskor a Dock ikon egy pillanatra felvillan, mert a policy csak az `init()`-ben állítódik.

**NSPanel `hidesOnDeactivate`:** alapból `true`. Most csak azért nem baj, mert `.prohibited` mellett az app soha nem deaktiválódik. Ha `.accessory`-ra váltasz, a panel eltűnik, amint más app kap fókuszt — azaz azonnal.

**Megoldás (Cosmos-minta):**
- `INFOPLIST_KEY_LSUIElement = YES` build setting → nincs Dock ikon, nincs cmd+tab bejegyzés, nincs felvillanás, és az app **`.accessory`** marad, ami ablakot készíthet.
- A `setActivationPolicy` hívások törlése az `init()`-ből.
- `hidesOnDeactivate = false` explicit a panelen (Cosmos így).
- A MenuBarExtra `.accessory`-val is működik (a Cosmos `NSStatusItem`-et használ, de az elv azonos).

---

## P2 — Kisebb hibák

### 11. ~~ELÉVÜLT~~ Felülírja a user kézi cmd+H-ját

> **Elévült:** a PLAN szerint nincs `hide()`/`unhide()`, tehát nincs mit felülírni. Ha a user cmd+H-zik egy ablakot, az rejtve marad, amíg ő elő nem hozza — a váltás nem nyúl hozzá.

`WorkspaceService.swift:69`: `appsToShow.filter(\.isHidden).forEach { unhide }`. Ha a user szándékosan elrejtett egy appot, a következő váltás előhozza.

**Ötlet:** `NSWorkspace.didHideApplicationNotification` / `didUnhideApplicationNotification` figyelése; egy `userHidden: Set<String>` halmaz, amit a saját `hide()` hívásaink *nem* töltenek fel (flag: „most én rejtek"). Váltáskor a `userHidden`-ben lévőket békén hagyni. Ez egyszerűbb, mint hangzik, de kérdés, hogy megéri-e — lehet, hogy elfogadható viselkedés, hogy a workspace-váltás „reset".

### 12. Key repeat nincs szűrve

`PanelService.handleKeyDown`: `event.isARepeat` nincs nézve. ctrl+opt+shift+1 nyomva tartva a `moveApp` ~30×/s fut: workspaces újraírás + SwiftUI re-render + `runningApplications` bejárás. **Megoldás:** `guard !event.isARepeat else { return true }` (cancel-elve, hogy a cél app se kapja meg).

### 13. keyUp nincs cancel-elve

Csak a keyDown-t nyeljük el; a cél app kap egy árva keyUp-ot „1"-re. A legtöbb app ignorálja; terminál-emulátorok, játékok, egyes Electron appok nem. **Megoldás:** `keyUp`-ra is feliratkozni, és ha a keyCode olyan, aminek a keyDown-ját elnyeltük (egy kis `Set<UInt16>` „pending cancel"), azt is cancel-elni.

### 14. Bundle ID nélküli app némán elnyelt

`PanelService.swift:43`: `guard let focusedAppBundleIdentifier else { return true }` — visszajelzés nélkül. **Ötlet:** `NSSound.beep()` vagy a HUD-on egy rövid „nem rendelhető" jelzés. Ritka eset (script-ből indított, egyes Java appok), a beep elég.

> A PLAN-ban ugyanez az elv a nem-manageable ablakra (`isManageable == false` → beep).

### 15. `hide()` / `unhide()` visszatérési érték ignorálva

Mindkettő `Bool`-t ad; sikertelenség észrevétlen marad. **Megoldás:** logolni (lásd 19. pont), és ha `hide()` `false`-t ad, egyszer újrapróbálni egy run loop-körrel később — a macOS néha visszautasítja, ha az app épp indul.

### 16. `NSImage` mutálása copy nélkül

`AppIconService.swift:28`: az `NSWorkspace.icon(forFile:)` által visszaadott képen állítjuk a `size`-t. Nincs garantálva, hogy nem shared példány. **Megoldás:** `(icon.copy() as! NSImage)` vagy a `size` beállítása helyett a SwiftUI oldalon `.frame(width:height:)` (ami már ott van — a `size` állítás valójában felesleges).

### 17. Notch-os menü bar magasság

`FloatingPanel.swift:37`: `NSStatusBar.system.thickness` nem egyezik a notch-os gépek tényleges menü bar magasságával. **Megoldás:** `screen.visibleFrame` használata — ez már levonja a menü bart és a Dockot. A Cosmos `DisplayProvider.swift:155-171` ugyanígy `visibleFrame`-ből számol insetet.

### 18. Dupla shortcut a `MenuContentView`-ban

`MenuContentView.swift:23-25`: ctrl+opt+1..4 `keyboardShortcut`-ként is fel van véve. Halott kód — menü-shortcut csak aktív appnál működne (soha), és a tap előbb cancel-eli. **Megoldás:** törölni. Ha vizuálisan akarod mutatni a shortcutot a menüben, `Toggle(isOn:)` + `.keyboardShortcut` helyett egyszerű `Text("⌃⌥\(id)")` trailing labelként.

### 19. `print()` → `os.Logger`

`WorkspaceService.swift:21,27,70,85`. Release buildben is kimennek, és egy globálisan privilegizált appnál a stdout-logolás nem oké (Console.app-ban nem szűrhető, nem kategorizált).

**Cosmos-minta (`Runtime/Log.swift`):** egy `Log` struct kategóriákkal, `Logger(subsystem:category:)`-re épül, `privacy: .public` (különben Console-ban `<private>`-ot látsz). A Cosmos ezenfelül ANSI-színezett stderr tükrözést is csinál külön queue-n — ez itt overkill, sima `os.Logger` elég:

```swift
enum Log {
    static let workspace = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "workspace")
    static let panel     = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "panel")
    static let tap       = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "tap")
}
// Log.workspace.info("Hide \(bundleId, privacy: .public)")
```

Szűrés: `log stream --predicate 'subsystem == "com.janosorcsik.SpaceRail"'`.

### 20. Unused import

`WorkspaceService.swift:9` — `import Combine` nincs használva. `SpaceRailApp.swift:8` — `import Cocoa` mellett `SwiftUI` is; a `Cocoa` elég lenne `AppKit`-ként. Trivialitás, a formatter/linter (lásd Infrastruktúra) úgyis kiszedi.

---

## Main thread tehermentesítés (Hashimoto-elv)

**Az elv:** az életciklus lehető legkorábbi pontján végezd el azokat a feladatokat, amik nem igénylik a main actort, külön `Task`-okban — hogy mire egy frame-et tényleg meg kell rajzolni, minden előkészítés készen legyen. A main actor render közben csak rajzol, nem számol és nem tölt be.

Ez itt kétszeresen fontos, mert a render a **tap callbackből** indul (2. pont): minden ms, amit a callbackben töltünk, az egész rendszer input-latencyje, és a tap letiltásának kockázata.

### Mi fut most a callbackben, aminek nem kellene

| Lépés | Hol | Költség | Hova tartozik |
|---|---|---|---|
| `runningApplications` bejárás | `removeClosedApps()` | O(n) proxy-objektum lekérés | `didTerminateApplicationNotification` figyelő — eseményvezérelt, nem kell pollolni |
| `frontmostApplication` lekérés | `handleFlagsChanged` | olcsó | maradhat, de csak átmenetnél (9. pont) |
| `setFrame` + `orderFront` | `showPanel()` | ablakszerver round-trip | `DispatchQueue.main.async` — a callback visszatér, a következő run loop-körön fut |
| SwiftUI render | `NSHostingView` | layout + kompozíció | ugyanott, async |
| `urlForApplication(withBundleIdentifier:)` | `AppIconService.get` | Launch Services DB lekérdezés | **előre**, háttér Task-ban |
| `icon(forFile:)` | `AppIconService.get` | diszk I/O, ICNS dekódolás | **előre**, háttér Task-ban |

### Javasolt szerkezet

**`AppIconService`** két metódussal:
- `cached(_ bundleID:) -> NSImage?` — csak a cache-t olvassa, **sosem** tölt be. Ezt hívja a `body`.
- `prefetch(_ bundleIDs: [String])` — `Task.detached(priority: .utility)`-ben feltölti a cache-t. `NSCache` thread-safe, `NSWorkspace.shared` metódusai háttérszálról hívhatók.

**Hívási pontok a `prefetch`-nek** (minél korábban):
1. `moveApp` végén — új app került a modellbe, az ikonja hamarosan kell.
2. `NSWorkspace.didLaunchApplicationNotification` — bármelyik új app potenciális jelölt.
3. App induláskor a már futó appokra (ha lesz perzisztencia, a mentett workspace-ek appjaira).

**A `body`** `cached(bundleId)`-t hív; ha nil → `app.dashed` placeholder. Amikor a háttér Task megjön, egy `@Observable` állapotfrissítés (pl. `iconVersion += 1` a modellen, vagy a cache egy Observable wrapper mögött) újrarenderel. A placeholder így a gyakorlatban sosem látszik, mert az ikonok már a HUD első megjelenése előtt betöltődtek.

**A tap callback** ezután:
```
handleFlagsChanged(event):
    let active = flags ⊇ overlayModifiers
    guard active != isOverlayActive else { return }     // átmenet-szűrés (9. pont)
    isOverlayActive = active
    DispatchQueue.main.async { active ? show() : hide() }
    // ← itt visszatér, ~mikroszekundum
```

**Accessibility check** is tartozik ide (5e. pont): az `init()` ne blokkoljon `runModal()`-lal; a check induljon el, és az eredménye szerint aszinkron jelenjen meg az alert vagy regisztrálódjanak a monitorok.

### Mérés

`os_signpost` a callback elejére/végére (`OSSignposter`), Instruments → Points of Interest. Cél: callback < 1 ms. Jelenlegi hideg cache-en valószínűleg 50–300 ms.

---

## Design-kérdések

Ezek nem hibák — döntés kell, mielőtt továbbépíted.

> **2026-09-21:** A és B eldőlt, a PLAN D2/D3/D4 rögzíti. A és B alább ~~ELÉVÜLT~~ jelöléssel marad az érvelés kedvéért. C (perzisztencia) érvényes, a PLAN Modell fejezete konkretizálja.

### A. ~~ELÉVÜLT~~ Hozzá nem rendelt appok elrejtése váltáskor

> **Döntés:** egyik opció sem — nincs elrejtés. A nem társított ablakok mindenhol látszanak, a workspace ablakai fölé kerülnek (PLAN D2, D3). Ez a „Sticky" opció szelleme, 5. UI-állapot nélkül.

`updateAppVisibility` **minden** olyan appot elrejt, ami nincs az aktuális workspace-ben — azokat is, amiket soha nem rendeltél sehová. Ezek utána nem jelennek meg maguktól; csak cmd+tab-bal vagy Dock-kattintással.

| Opció | Viselkedés | Előny | Hátrány |
|---|---|---|---|
| **Jelenlegi** | hozzá nem rendelt = rejtve minden workspace-en | tiszta workspace-ek | új appok „elvesznek" váltás után; első használatnál minden eltűnik |
| **Érintetlen** | hozzá nem rendelt appok soha nem rejtődnek | nincs meglepetés | workspace-ek „zajosak" a közös appoktól |
| **Sticky** | hozzá nem rendelt = minden workspace-en látható (explicit „globális" kategória) | a kettő előnye | egy 5. állapot a UI-ban |

A Cosmos (ablak-szintű, valódi Spaces-kezelés) az „érintetlen" felé hajlik: amit nem parkolt le, azt nem bántja. HUD-alapú workspace-nek valószínűleg a **Sticky** a legjobb: ami nincs sehova rendelve, az mindenhol van (Finder, Slack, Music tipikusan ilyen), és a workspace-ek csak a *specifikus* appokat kapcsolgatják.

### B. ~~ELÉVÜLT~~ cmd+tab kilyukasztja a hide-alapú workspace-eket

> **Döntés:** a 2. opció szelleme (auto-váltás arra a workspace-re, ahol az ablak van — PLAN D4), de hide nélkül, ezért „kilyukasztás" sincs. A 3. opció (ablak-szint) megvalósul, **de** parkolás nélkül — a PLAN nem az AX-parkolást, hanem az előrehozást választja, így az „~500 sor AX réteg" becslés túlzó lett: a motor ~150–200 sor.

`NSRunningApplication.hide()` csak elrejt; az app marad a cmd+tab listában, és kiválasztva unhide-olódik. Egy „másik workspace-en lévő" app egy cmd+tab-bal előjön, és ott marad a következő váltásig. Ez a hide-alapú megközelítés **elvi korlátja**, nem hiba.

Opciók, növekvő komplexitással:
1. **Elfogadni.** Sok user pont ezt akarja: a workspace egy „alapállapot", amitől ad hoc el lehet térni.
2. **Visszarejteni.** `didUnhideApplicationNotification` / `didActivateApplicationNotification` figyelése: ha egy másik workspace appja előjön, automatikusan átváltani arra a workspace-re (a HUD megmutatja). Ez a legkisebb munka a legnagyobb konzisztenciáért.
3. **Ablak-szintű kezelés.** Cosmos-út: AX API-val egyedi ablakokat parkolni (off-screen frame), megőrizve az eredeti pozíciót. Egy app két ablaka különböző workspace-re kerülhet. Ez lényegében újraírás (`Sources/CosmosCore/MacOS/AXClient.swift` ~500 sor csak az AX réteg). Csak ha a projekt komolyra fordul.
4. **Privát Spaces API** (yabai/Cosmos `PrivateApi` target). SIP-függő, macOS-verziónként törik. Nem javasolt.

### C. Perzisztencia

README roadmap: „Persist app assignments". Jelenleg minden újraindításnál üres.

Egyszerű út: `Codable` `[Workspace]` → JSON `~/Library/Application Support/<dataDirectoryName>/workspaces.json`. A `dataDirectoryName` az `AppProfile`-ból jön (lásd Gyors nyereségek 2.2), így a dev build nem írja felül az éleset.

Mit mentsünk: bundle ID-ket (nem PID-et). Betöltéskor a nem futó appok maradnak a listában (ikon `app.dashed`-del vagy halványítva), és amikor elindulnak, automatikusan a helyükre kerülnek — ez a `didLaunchApplicationNotification` figyelővel egy sor.

Kérdés: a `selectedWorkspaceId`-t is mentsük? Valószínűleg nem — induláskor minden app látható, „1" a semleges állapot.

---

## Gyors nyereségek

Kevés munka, komoly napi előny. (Az eredeti Cosmos-notes 2. szakasza.)

### 2.1 `Config/Version.xcconfig`

```
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1
DEVELOPMENT_TEAM = 4YLAALG7M5
```

`baseConfigurationReference`-ként bekötve Debugra és Release-re. A Cosmos ugyanígy (`Apps/Cosmos/Version.xcconfig`), a `set-version.sh` scriptje ezt írja. A beégetett `DEVELOPMENT_TEAM` sorok kikerülnek a `project.pbxproj`-ból.

Bundle ID javítása reverse-DNS-re: `janosorcsik.SpaceRail` → `com.janosorcsik.SpaceRail`. **Figyelem:** a bundle ID változás új TCC-bejegyzést jelent — újra kell adni az Accessibility engedélyt.

### 2.2 Dev/release profil izoláció (`AppProfile`)

Window managernél a debug build most szétlövi az éles munkakörnyezetedet: ugyanaz a bundle ID, ugyanazok a hotkeyek, ha lesz perzisztencia, ugyanaz a fájl.

Cosmos-minta (`Runtime/AppProfile.swift`):
- Debug: `PRODUCT_NAME = "SpaceRail Dev"`, `PRODUCT_BUNDLE_IDENTIFIER = com.janosorcsik.SpaceRail.debug`
- Release: `SpaceRail`, `com.janosorcsik.SpaceRail`
- Swift oldalon:

```swift
struct AppProfile {
    static let debug = AppProfile(dataDirectoryName: "spacerail-dev")
    static let release = AppProfile(dataDirectoryName: "spacerail")
    static var current: AppProfile { #if DEBUG .debug #else .release #endif }
    let dataDirectoryName: String
    var stateURL: URL { /* Application Support / dataDirectoryName / workspaces.json */ }
}
```

Ötlet SpaceRail-specifikusan: dev buildben **más hotkey-modifier** (pl. ctrl+opt+cmd), hogy az éles és a dev egymás mellett futhasson anélkül, hogy mindkettő elkapja a ctrl+opt-ot. Az `AppProfile` tartalmazhatja az `overlayModifiers`-t.

### 2.3 `print()` → `os.Logger`

Lásd P2/19.

### 2.4 `LSUIElement`

Lásd P1/10.

### 2.5 `scripts/reset-permissions.sh`

Az Accessibility flow ismételt teszteléséhez (Cosmos `scripts/clear.sh` mintája, ami a `tccutil reset All <bundle-id>`-t és az onboarding defaults-ot is nullázza):

```zsh
#!/bin/zsh
set -euo pipefail
profile="${1:?Usage: $0 <dev|release>}"
case "$profile" in
    dev)     bundle_id="com.janosorcsik.SpaceRail.debug" ;;
    release) bundle_id="com.janosorcsik.SpaceRail" ;;
    *)       print -u2 "Profile must be dev or release."; exit 1 ;;
esac
tccutil reset Accessibility "$bundle_id"
```

---

## Infrastruktúra

Akkor éri meg, ha ki akarod adni / megosztani. (Az eredeti Cosmos-notes 3. szakasza + az 1.2 shared scheme.)

### Shared scheme (előfeltétel minden továbbihoz)

`SpaceRail.xcodeproj/xcshareddata/xcschemes/` **nem létezik**. `xcodebuild -list` üres Schemes listát ad; `xcodebuild -scheme SpaceRail` tiszta klónon elhasal. Xcode → Product → Scheme → Manage Schemes → „Shared" pipa. Ez blokkol minden scriptet és CI-t.

*(Az eredeti notes 1.1 pontja — `.gitconfig` → `.gitignore` átnevezés, `xcuserdata` untrack — már megtörtént a `1ae198c` commitban; `git ls-files` szerint rendben.)*

### `.swiftformat` + `.swiftlint.yml`

Cosmos-minta, minimál (`macos/.swiftformat`, `macos/.swiftlint.yml`):

```
--swift-version 5.9
--indent 4
--exclude .build,.swiftpm
--trailing-commas never
--disable wrapMultilineStatementBraces
```

```yaml
included: [SpaceRail]
reporter: "xcode"
identifier_name:
  excluded: [x, y, id]
```

Indok: a `433fc0d "Fix formatting"` commit (8 fájl, +60/−54) pont az a churn, amit egy formatter megszüntet. Megjegyzés: a jelenlegi kódban trailing comma van (`apps: filteredApps,`) — ez Swift 6.1+ feature, a Cosmos `never`-t használ; dönts.

### `scripts/` + `justfile`

Cosmos-elv: a justfile **nulla logikát** tartalmaz, minden recept egysoros delegálás egy scriptre — így a CI közvetlenül a scriptet hívja, nem kell `just` a runnerre.

```
set shell := ["zsh", "-cu"]
build profile:   ./scripts/build.sh {{quote(profile)}}
run profile:     ./scripts/run.sh {{quote(profile)}}
fmt:             ./scripts/format.sh
lint:            ./scripts/lint.sh
check:           ./scripts/check.sh
clear profile:   ./scripts/reset-permissions.sh {{quote(profile)}}
```

Egységes preambulum minden scriptben (Cosmos `build.sh`):
```zsh
#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
```

`build.sh <dev|release>` — `xcodebuild -quiet -project ... -scheme SpaceRail -configuration Debug|Release -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath .build/xcode`. `SPACERAIL_SKIP_CODE_SIGNING=1` env → `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`, hogy CI tanúsítvány nélkül tudjon buildelni.

`check.sh` = `build.sh dev` (+ `test.sh`, ha lesz teszt). `lint.sh` = `swiftlint lint` (Cosmos itt `periphery scan`-t is futtat — lásd „nem veszünk át"). `format.sh` = `swiftformat SpaceRail`.

### `.github/workflows/ci.yml`

Cosmos-minta egyszerűsítve: egyetlen `check` job, egy runner (`macos-26`, mert a deployment target 26.0), `paths:` szűrő (doc-only commitok ne fussanak), `permissions: contents: read`, `concurrency` group `cancel-in-progress`-szel, `SPACERAIL_SKIP_CODE_SIGNING: "1"`, `run: ./scripts/check.sh`. Külön `lint` job `brew install swiftlint swiftformat` után. Előfeltétel: shared scheme.

### `LICENSE`

Cosmos: Apache 2.0. MIT is jó. Nélküle a publikus repo jogilag használhatatlan mások számára.

### README kiegészítés

- macOS 26 követelmény (jelenleg nincs benne — `.glassEffect()` miatt kemény korlát)
- Build utasítás (`just build dev` vagy `xcodebuild` parancs)
- Accessibility engedély lépései (a 5. pont javított flow-jával egyszerűbb lesz)
- Screenshot/GIF a HUD-ról
- A B. design-kérdés eldöntése után: mit csinál a cmd+tab

---

## Architektúra (távlati)

Jelenleg **nem javasolt** elkezdeni; rögzítve az irány. (Az eredeti Cosmos-notes 4. szakasza.)

- **Protokoll seam-ek + DI.** A három `static let shared` singleton (`PanelService`, `WorkspaceService`, `AppIconService`) és a View-k közvetlen `WorkspaceService.shared.model` elérése blokkolja a tesztelést. A Cosmos protokollokat (`WindowSystem`, `AppLaunching`, `AXClient` stílusban) + kézzel írt fake-eket használ. Ez a tesztelés előfeltétele, nem fordítva — először a seam, aztán a teszt.

- **Ablak-szintű kezelés app-szintű helyett.** ~~Távlati~~ → **ez lett a PLAN.** A Cosmos `AXClient.swift` a referencia: `AXUIElementSetAttributeValue(kAXMainAttribute)` + `kAXRaiseAction` + `runningApp.activate()` a fókuszhoz. ~~frame-mentés + off-screen parkolás a rejtéshez~~ — parkolás nincs, csak frame-visszaállítás a workspace saját ablakaira. Így nem újraírás, hanem a motor cseréje; a panel, a menü bar és a tap-réteg marad.

- **SPM package + vékony Xcode shell.** Cosmosnál a logika egy SPM package-ben van, az `.xcodeproj` egy héj (`main.swift` egyetlen sor). A logika `swift test`-tel fut, csak az app-hostolt tesztek igényelnek `xcodebuild`-ot. Csak ha a kódbázis jelentősen nő.

- **NSWorkspace notification-alapú modell.** Cosmos `WindowEventMonitor.swift:104-147`: `didLaunchApplication`, `didTerminateApplication`, `didActivateApplication` + `sessionDidResignActive`/`sessionDidBecomeActive` (fast user switching) + `willSleep`/`didWake`. SpaceRail-nek az első három elég (több P1/P2 pont ezekre épül), a session/sleep figyelés akkor kell, ha az event tap alvás után nem tér vissza — ezt tesztelni kell.

---

## Átvehető a mycast-ból

**Referencia:** `/Users/janosorcsik/Developer/mycast` — macOS 26, Swift 6, SwiftUI + AppKit, Raycast-ihlette launcher. Hasonló méretkategória (nem 50k+ soros), ugyanolyan infrastruktúrán fut (LSUIElement, Accessibility, CGEventTap, nonactivating HUD panel). Az alábbiak konkrét, önálló fájlok, amelyek minimális adaptációval átmásolhatók.

### M1. `Platform/KeyboardTap.swift` — egyetlen, újraengedélyező tap wrapper

Ez az egyetlen legértékesebb átvehető darab. A mycast egy ~120 soros, session-szintű `CGEventTap` wrappert épített, ami:

- **kezeli a tap-letiltást** (`tapDisabledByTimeout`, `tapDisabledByUserInput`): azonnal `CGEvent.tapEnable(tap:enable:true)`-t hív, majd újraszinkronizálja a modifier állapotot — ez a SpaceRail P0/2 gyökere;
- **több handler regisztrálhat rá** (`add(_:)` / `remove(_:)`): az első, aki igényli, indítja a tapet; az utolsó, aki lejelentkezik, leállítja;
- **lazy indul és clean leáll**: nincs globális singleton-init, nincs félbehagyott tap;
- tartalmaz egy `CGEvent.typedCharacters` extension-t, ami az aktuális billentyűkiosztás szerint dekódolja az event karakterét — a `WorkspaceKey` enum `rawValue - 17` trükkjét ki lehet váltani ezzel.

**Döntés (PLAN D12, D13): ~~NEM KELL~~.** Először ez volt a választott út a ⌃⌥⌘-tartás (HUD hold) miatt. A hold elvetésével (D12) a tap egyetlen előnye sem maradt; helyette `sindresorhus/KeyboardShortcuts` (Carbon), lásd W1. Ha valaha modifier-tartás vagy modifier-only chord kellene, ez a fájl a válasz — addig nem.

**Adaptáció:** az egyetlen mycast-specifikus függőség az `os.Logger` import — az egyébként független. Az event típusmaszk (`[.keyDown, .keyUp, .flagsChanged]`) és a tap helye (`.cgSessionEventTap`, `.headInsertEventTap`) pontosan ugyanaz, ami a SpaceRailnek kell.

### M2. ~~NEM KELL~~ `Platform/KeyChord.swift` — gépelt billentyűkombináció value type

> **PLAN D13:** a `KeyboardShortcuts.Shortcut` (Codable, Sendable, Carbon-konverzióval) ugyanezt adja, plusz tárolást és recorder UI-t. Nincs mit átvenni.

```swift
nonisolated struct KeyChord: Hashable, Codable, Sendable {
    var keyCode: UInt16
    var modifiers: Modifiers   // OptionSet: control / option / shift / command
}
```

- `Modifiers.symbols` → `"⌃⌥"` display string a menü bar tooltiphez és a README-hez;
- `keyName(_:)` → `UCKeyTranslate` alapú, layout-helyes billentyűnév (az `1` billentyű nem mindig `"1"` más kiosztásokon);
- `Codable` → a „Customizable keyboard shortcuts" roadmap-pont alapja lesz.

Felváltja a `WorkspaceKey.swift` `UInt16 enum rawValue - 17` trükkjét. A `Modifiers.hyper` alias (`[.control, .option, .command]`) a 2.2 `AppProfile` dev-modifier ötlethez is jól jön.

### M3. `Platform/Permissions.swift` — `AXIsProcessTrustedWithOptions` wrapper

A mycast megoldja a P1/5b pontot:

```swift
func ensureAccessibilityPermission(prompt: Bool) -> Bool {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
}
```

`prompt: true` → a rendszer maga adja hozzá az appot a Privacy listához és feldobja a dialógust. Pontosan a Cosmos-mintával megegyező megoldás, de a mycast-ból is másolható, ha ott látod előbb.

### M4. `Platform/Preferences.swift` — gépelt `UserDefaults` wrapper

Szükség lesz rá, amint a C (perzisztencia) design-döntés megvalósul. A mycast wrapperje `@propertyWrapper`-alapú, `Codable` értékeket tárol JSON-ként, és test-futtatáshoz az alapértelmezés felülírható. Közvetlen előfeltétele a `selectedWorkspaceId` és az `AppProfile` megőrzésének.

### M5. `HUD/HUDPanel.swift` — NSPanel trükkök

Nem másolandó egészben (a mycast HUD-ja sokkal összetettebb), de **három konkrét beállítás** beemelendő, amit a mycast is alkalmaz és a SpaceRail P1/4, P1/7, P1/10 javításánál szükséges:

```swift
panel.isReleasedWhenClosed = false   // P1/10 — panel ne szabaduljon fel hidekor
panel.hidesOnDeactivate = false      // P1/10 — .accessory policyval ne tűnjön el
panel.ignoresMouseEvents = true      // P1/7  — ne nyeli el a kattintásokat
// collectionBehavior:
[.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]  // P1/4 — fullscreen fölé is megy
```

A mycast és a winmux egymástól függetlenül ugyanerre a négy beállításra jutott — ez megerősíti, hogy ez a helyes recept.

### Amit a mycast-ból NEM érdemes átvenni

- **`HotKeys/HyperKey.swift`**: Caps Lock → Hyper key state machine. Komplex, SpaceRailnek nem kell.
- **`Snippets/KeywordExpander.swift`** és **`Platform/TextPaster.swift`**: snippet/paste funkciók, irrelevansak.
- **`Platform/FrontmostSelection.swift`**: AX-alapú szövegkijelölés-olvasás, nem kell.
- A teljes HUD/Launcher/Calculator/Quicklinks réteg — más app, más cél.

---

## Ötletek a winmux-ból

**Referencia:** `/Users/janosorcsik/Developer/winmux` — AeroSpace-alapú tiling window manager, 54k sor Swift, 1764 commit, macOS 13+. Nem hasonló projekt: teljes AX-alapú ablakkezelő, Sparkle, TOML config, 70 tesztfájl. A legtöbb megoldása nagyságrenddel nagyobb problémára van szabva. Az alábbiak azok, amik a SpaceRail **konkrét hibáira** illenek.

### W1. **VÁLASZTOTT** Carbon hotkey a keyDown-ra, tap helyett — megszünteti a P0/2 és P0/3 gyökerét

> **Döntés (PLAN D12, D13):** ez lett, a `soffes/HotKey` helyett `sindresorhus/KeyboardShortcuts`-szal (ugyanaz a Carbon alap, plusz recorder UI + UserDefaults tárolás a Settingshez). A lenti „ctrl+opt tartás → global monitor" rész **nem kell**, mert a HUD-nak saját toggle shortcutja van — így az app semmilyen billentyű-eseményt nem figyel a hotkey-eken kívül.

A winmux a billentyűkombinációkat **nem** CGEventTap-pel kapja el, hanem a `soffes/HotKey` könyvtárral, ami a Carbon `RegisterEventHotKey`-t csomagolja (`config/HotkeyBinding.swift:25-239`). A rendszer natívan elnyeli a kombinációt, a cél app nem kapja meg, **nincs beep**, nincs tap, nincs timeout-letiltás.

SpaceRail-re alkalmazva:
- **ctrl+opt+1..4 és ctrl+opt+shift+1..4** → 8 db `RegisterEventHotKey` (vagy a HotKey lib, ~300 sor, MIT). Nem kell hozzá `.defaultTap`, nem kell `cancel()`, nem kell a keyUp-ot külön elnyelni (P2/13), key repeat sem jön (P2/12 — Carbon hotkey csak keyDown-t ad).
- **ctrl+opt lenyomva tartás (HUD)** → `NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)` — a winmux is ezt használja (`GlobalObserver.swift:158`). Passzív, nem tiltható le timeout miatt, nem blokkolja az eseményfolyamot. Accessibility engedély kell hozzá, de az amúgy is van.
- Eredmény: a CGEventSupervisor **teljesen elhagyható**. P0/2 (tap-letiltás) és P0/3 (branch=main pin) megszűnik, a Main thread fejezet callback-tehermentesítése egyszerűsödik (a global monitor handlerje már a main run loopon, az eseményfolyam blokkolása nélkül fut).
- Ellenőrizendő: Carbon hotkey Secure Input alatt is működik-e a te setupodban (általában igen — ez a Carbon hotkey egyik ismert előnye a tappel szemben).
- Trade-off: a Carbon API deprecated-jelölés nélküli, de „legacy" — 2026-ban is működik, Apple nem távolította el, minden hotkey-app ezt használja (Alfred, Raycast, Rectangle).

### W2. Secure Input jelzés — a „némán meghal" tünet láthatóvá tétele

`ui/settings/SecureInputView.swift:8-43`: a winmux `IsSecureEventInputEnabled()`-del (Carbon) ellenőrzi, hogy aktív-e a Secure Input, és ha igen, egy kis `lock.shield.fill` badge-et mutat a képernyő sarkában; kattintásra kifejti a magyarázatot. `refresh()`-t hív minden layout-frissítésnél és config-reloadnál.

SpaceRail-re: ha a HUD megjelenésekor `IsSecureEventInputEnabled()` igaz, a HUD-on egy lakat ikon (vagy a menü bar ikon változik). Így a user tudja, hogy *miért* nem reagál a hotkey, nem az appot hibáztatja. Akkor is hasznos, ha a W1-et megcsinálod — ha a Carbon hotkey mégsem működne Secure Input alatt.

### W3. cmd+H kezelés konfig-kapcsolóval (P2/11)

`GlobalObserver.swift:27-49`: `didHideApplicationNotification` figyelő + `config.automaticallyUnhideMacosHiddenApps` kapcsoló. A winmux viselkedése az ellenkező irány (mindent unhide-ol, mert neki a hide zavaró), de a **minta** átvehető: figyelő a hide/unhide notificationre, és egy user-döntés, hogy a workspace-váltás tiszteletben tartja-e a kézi elrejtést. Ne találd ki helyette — legyen kapcsoló.

### W4. Bal/jobb modifier megkülönböztetés

`config/TapBinding.swift:36-57`: `NX_DEVICELALTKEYMASK` / `NX_DEVICERALTKEYMASK` stb. device-specifikus flagekkel megkülönbözteti a bal és jobb Option-t; ha a flags-ben van device-specifikus bit, azt nézi, különben a generikus maszkot.

SpaceRail-re: ha a ctrl+opt ütközik valamivel (pl. terminál, IDE), egy **„csak jobb Option"** opció megoldja anélkül, hogy a shortcut-testreszabást (README roadmap) teljesen meg kellene írni. ~20 sor.

### W5. Hotkey-felfüggesztés shortcut-rögzítés közben

`config/HotkeyBinding.swift:54-62` + `ui/settings/ShortcutRecorderView.swift:21,51`: amikor a user új shortcutot rögzít a Settingsben, `setHotkeysSuspended(true)` — különben a rögzítés közben lenyomott kombináció kiváltja a régi akciót. A README „Customizable keyboard shortcuts" roadmap-pontjához előfeltétel. A winmux MASShortcut-ot használ a recorder UI-ra; egy 4 hotkey-es appnak elég egy saját, ~50 soros recorder.

### W6. Launch at login — `SMAppService`

`startAtLogin.swift:9-17`: `SMAppService.mainApp.register()` / `.unregister()`. Öt sor, macOS 13+. Egy menü bar workspace-appot induláskor akarsz — ez hiányzik a README roadmapról. `LSUIElement` + `SMAppService` = tiszta, LaunchAgent plist nélkül.

### W7. XcodeGen (`project.yml`) a `project.pbxproj` kézi szerkesztése helyett

A winmux a projektet `project.yml`-ből generálja (XcodeGen). Ez a SpaceRail több infrastruktúra-pontját egyszerre oldja meg: shared scheme automatikusan generálódik, per-config bundle ID / product name / `LSUIElement` / sandbox-kikapcsolás mind egy ~40 soros YAML-ban, a `pbxproj` nem kerül git-be (nincs merge-konfliktus, nincs beégetett team ID). Hátrány: egy plusz tool (`brew install xcodegen`), és a Xcode-ban végzett projektbeállítás-módosítások elvesznek — mindent a YAML-ban kell csinálni. Egy 10 fájlos projektnél megéri megfontolni, **ha** a Gyors nyereségek 2.1/2.2 és az Infrastruktúra/shared scheme pontokat amúgy is megcsinálod.

### W8. `NSPanelHud` alaposztály

`ui/NSPanelHud.swift:3-21`: ugyanaz a recept, mint a Cosmosnál — `[.nonactivatingPanel, .borderless]`, `.canJoinAllSpaces + .fullScreenAuxiliary`, `isReleasedWhenClosed = false`, `hidesOnDeactivate = false`, `isOpaque = false`, `backgroundColor = .clear`. Két független projekt ugyanarra jutott → a P1/4 és P1/10 javítás iránya megerősítve. A winmux `.floating` szintet használ (nem `.statusBar`), és neki működik fullscreen fölött is — tehát a `.fullScreenAuxiliary` a kulcs, a szint másodlagos.

### W9. Tesztelhetőség DI nélkül: override-hook

`Monitor.swift:101-104`: `nonisolated(unsafe) private var monitorsOverrideForTests: [Monitor]?` + `setMonitorsForTests(_:)`. Singleton-alapú kódban a tesztek egy globális override-on keresztül cserélik ki a rendszer-függő adatot, protokoll-réteg nélkül. Az Architektúra fejezet „protokoll seam" javaslatának olcsóbb alternatívája, ha csak a `runningApplications` és a `NSScreen.screens` kimenetét akarod fake-elni. Kevésbé tiszta, de 439 soros projektnél arányos.

### Amit a winmux-ból NEM érdemes

- **Accessibility flow** (`accessibility.swift:5-12`): `prompt: true`, ha nem trusted → `tccutil reset` + terminate. Rosszabb, mint a Cosmos poll-alapú megoldása (P1/5); a `tccutil reset` a user TCC-döntését is törli.
- **Ikon cache** (`ui/core/AppIconProvider.swift`): main threaden, prefetch nélkül — pont az, amit a Main thread fejezet elkerülni javasol.
- AX-alapú ablakkezelés, per-app AX thread, dual timeout, tab groupok, projects, Sparkle, TOML config, MASShortcut, sidebar — a B/3 design-döntés (ablak-szint) *után* válnak relevánssá, előtte nem.

---

## Szándékosan nem veszünk át

Notarizálás + DMG + Homebrew cask pipeline (`notarize.sh`, `package.sh`, `release.sh`), Hugo docs site, Periphery dead-code CI gate, 3-OS CI mátrix (`macos-14`/`macos-15-intel`/`macos-26`), ANSI-színezett stderr log-tükrözés, fixture app a tesztekhez. Ezek egy 126 commitos, kiadott terméknél térülnek meg — egy hobbi projektnél most csak karbantartási teher.

---

## Javasolt sorrend

> **2026-09-21:** a sorrendet a **[`PLAN.md` Sorrend fejezete](PLAN.md#sorrend)** váltja. Az alábbi az eredeti; a hozzárendelés a PLAN lépéseihez:

1. ~~**P0 mindhárom**~~ → PLAN 1. lépés (konfig + KeyboardShortcuts). W1 lett, tap nincs.
2. ~~**Main thread tehermentesítés**~~ → PLAN 4. lépés (ikon prefetch). A tap-callback része tárgytalan.
3. ~~**P1 4, 5, 6, 7, 10**~~ → PLAN 1. lépés (konfig, permission, panel).
4. ~~**A. és B. design-döntés**~~ → eldőlt, PLAN D2–D4.
5. **Gyors nyereségek** — AppProfile a PLAN 2. lépésében (perzisztencia mappa).
6. **P2** — ahogy jön; a linter/formatter (Infrastruktúra) a 20-at magától megoldja.
7. **Infrastruktúra** — ha megosztod a projektet.
8. ~~**Architektúra** — csak ha a B/3 (ablak-szint) irányba mégy.~~ → ez lett a PLAN, parkolás nélkül.
