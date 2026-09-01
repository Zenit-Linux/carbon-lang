(def stage (os/getenv "ZPM_PACKAGE_STAGE_DIR"))

(defn fail [msg]
  (eprint "recipe.janet: " msg)
  (os/exit 1))

(defn run [cmd]
  # `os/shell` zwraca kod wyjścia polecenia (jak C-owe system()) --
  # zero == sukces.
  (def code (os/shell cmd))
  (unless (zero? code)
    (fail (string "'" cmd "' zakończone kodem " code))))

(defn try-run [cmd]
  # Jak `run`, ale nie przerywa recipe przy niepowodzeniu -- zwraca
  # true/false. Do kroków, które są "najlepszym wysiłkiem"
  # (instalacja zależności różnymi metodami po kolei).
  (zero? (os/shell cmd)))

(defn shell-out [cmd]
  # Uruchamia polecenie i zwraca [ok stdout-przycięte]. W
  # przeciwieństwie do `run`/`try-run` nigdy sam nie failuje --
  # wywołujący decyduje, co zrobić z `ok`.
  (def proc (os/spawn ["/bin/sh" "-c" cmd] :p {:out :pipe}))
  (def out (:read (proc :out) :all))
  (def code (:wait proc))
  [(zero? code) (string/trimr (or out ""))])

(defn have? [tool]
  (zero? (os/shell (string "command -v " tool " >/dev/null 2>&1"))))

(defn root? []
  (zero? (os/shell "test \"$(id -u)\" = 0")))

(defn sudo- []
  (if (root?) "" (if (have? "sudo") "sudo " "")))

(defn ensure-dir [path]
  (try (os/mkdir path) ([_] nil)))

(defn ensure-dir-p [path]
  (var acc "")
  (each part (string/split "/" path)
    (when (> (length part) 0)
      (set acc (string acc "/" part))
      (ensure-dir acc))))

# ---------------------------------------------------------------------
# Auto-instalacja brakujących narzędzi -- wykrywa menedżer pakietów
# (apt/dnf/pacman/zypper/apk/brew), nie tylko apt/Debian. `pkgs-by-pm`
# to struct {:apt "..." :dnf "..." :pacman "..." :zypper "..." :apk
# "..." :brew "..."} -- brakujący klucz dla wykrytego menedżera po
# prostu pomija ten krok (wywołujący ma wtedy własny fallback).
# ---------------------------------------------------------------------

(defn detect-pm []
  (cond
    (have? "apt-get") :apt
    (have? "dnf") :dnf
    (have? "pacman") :pacman
    (have? "zypper") :zypper
    (have? "apk") :apk
    (have? "brew") :brew
    :none))

(defn pm-install [pkgs-by-pm]
  (def pm (detect-pm))
  (def pkgs (get pkgs-by-pm pm))
  (if (not pkgs)
    false
    (let [sudo (sudo-)]
      (case pm
        :apt (try-run (string sudo "apt-get update && " sudo "env DEBIAN_FRONTEND=noninteractive apt-get install -y " pkgs))
        :dnf (try-run (string sudo "dnf install -y " pkgs))
        :pacman (try-run (string sudo "pacman -Sy --noconfirm " pkgs))
        :zypper (try-run (string sudo "zypper --non-interactive install " pkgs))
        :apk (try-run (string sudo "apk add --no-cache " pkgs))
        :brew (try-run (string "brew install " pkgs))
        false))))

(defn ensure-tool [tool pkgs-by-pm]
  # Najprostszy przypadek: jedno narzędzie, jedna próba instalacji.
  # Dla Clang/LLD/uv/bazel poniżej używamy bardziej rozbudowanej
  # logiki (wersje, alternatywne źródła instalacji).
  (unless (have? tool)
    (eprint "recipe.janet: brak '" tool "' -- próbuję zainstalować automatycznie (" (detect-pm) ")...")
    (pm-install pkgs-by-pm))
  (have? tool))

# ---------------------------------------------------------------------
# Carbon nie ma tagowanych wydań (patrz komentarz w zpk.build) -- nie
# ma więc "źródła" do pobrania w postaci tarballa releasu. Ta recipe
# klonuje repo samodzielnie, chyba że operator już ma checkout gotowy
# (ZPK_PACKAGING_SRC_DIR) -- np. w CI, gdzie sklonowanie i ewentualne
# przypięcie konkretnego commita robi osobny, wcześniejszy krok.
# ---------------------------------------------------------------------

(unless (ensure-tool "git" {:apt "git" :dnf "git" :pacman "git" :zypper "git" :apk "git" :brew "git"})
  (fail "brak 'git' i nie udało się go automatycznie zainstalować"))

(def repo-url "https://github.com/carbon-language/carbon-lang")

# Domyślnie budujemy `trunk` (jedyna "stabilna z definicji" gałąź w
# tym repo -- nie ma release/*). Ustaw CARBON_LANG_REF, żeby przypiąć
# konkretny commit/tag do reprodukowalnych buildów.
(def ref (or (os/getenv "CARBON_LANG_REF") "trunk"))

(def existing-src (os/getenv "ZPK_PACKAGING_SRC_DIR"))

(def src-dir
  (if (and existing-src (> (length existing-src) 0))
    existing-src
    (do
      (def work-dir (string (os/cwd) "/build"))
      (ensure-dir work-dir)
      (def dir (string work-dir "/carbon-lang"))
      (unless (os/stat dir :mode)
        (run (string "git clone --filter=blob:none " repo-url " " dir)))
      (run (string "cd " dir " && git fetch --depth=1 origin " ref
                   " && git checkout FETCH_HEAD"))
      dir)))

(unless (os/stat src-dir :mode)
  (fail (string "katalog źródeł nie istnieje: " src-dir)))

# Katalog na lokalne symlinki/binarki (shim'y) narzędzi budowania,
# dodawany na początek PATH tylko dla tego builda -- nigdy nie
# dotykamy systemowego /usr/bin ani `update-alternatives`, więc
# działa bez roota i nie koliduje z niczym już zainstalowanym.
(def tool-shim-dir (string (os/cwd) "/.zpk-tool-shims"))
(ensure-dir tool-shim-dir)
(os/setenv "PATH" (string tool-shim-dir ":" (os/getenv "PATH")))

(def prebuilt (os/getenv "ZPK_PACKAGING_PREBUILT_BAZEL_BIN"))

(def bazel-bin-dir
  (if (and prebuilt (> (length prebuilt) 0))
    # CI/operator już zbudowało toolchain wcześniej w tym samym biegu
    # (np. osobny krok `bazel build //toolchain //explorer`) -- nie
    # buduj drugi raz, użyj gotowego katalogu bazel-bin. Pomijamy też
    # całą poniższą logikę instalowania Clang/LLD/uv/bazel.
    prebuilt
    (do
      # -----------------------------------------------------------
      # Clang/LLVM >= 19 i LLD. Szukamy najpierw jawnie zwersjonowanych
      # binarek (clang++-19..24 itd. -- typowe dla apt.llvm.org i
      # pakietów dystrybucyjnych, gdzie "clang++" bez numeru bywa
      # starszą wersją domyślną albo w ogóle nie istnieje), a dopiero
      # potem "gołej" nazwy, dla której realnie sprawdzamy wersję.
      # -----------------------------------------------------------
      (def MIN-CLANG 19)
      (def clang-versioned ["clang++-24" "clang++-23" "clang++-22" "clang++-21" "clang++-20" "clang++-19"])
      (def clangc-versioned ["clang-24" "clang-23" "clang-22" "clang-21" "clang-20" "clang-19"])
      (def lld-versioned ["ld.lld-24" "ld.lld-23" "ld.lld-22" "ld.lld-21" "ld.lld-20" "ld.lld-19"])

      (defn find-first [candidates]
        (var result nil)
        (each c candidates
          (when (and (not result) (have? c)) (set result c)))
        result)

      (defn binary-major-version [bin]
        (def [ok out] (shell-out (string bin " --version 2>/dev/null | head -1")))
        (if (not ok)
          0
          (let [m (peg/match ~(* (thru "version ") (<- (some :d))) out)]
            (if m (scan-number (m 0)) 0))))

      (defn find-adequate [versioned bare min-major]
        (def v (find-first versioned))
        (cond
          v v
          (and (have? bare) (>= (binary-major-version bare) min-major)) bare
          nil))

      (defn resolve-toolchain []
        [(find-adequate clang-versioned "clang++" MIN-CLANG)
         (find-adequate clangc-versioned "clang" MIN-CLANG)
         (find-adequate lld-versioned "ld.lld" MIN-CLANG)])

      (var toolchain-found (resolve-toolchain))
      (var cxx (toolchain-found 0))
      (var cc (toolchain-found 1))
      (var lld (toolchain-found 2))

      (when (not (and cxx cc lld))
        (eprint "recipe.janet: brak odpowiedniego Clang/LLVM >= " MIN-CLANG " i/lub LLD -- próbuję zainstalować (" (detect-pm) ")...")
        (pm-install {:apt "clang lld" :dnf "clang lld" :pacman "clang lld" :zypper "clang lld" :apk "clang lld" :brew "llvm lld"})
        (set toolchain-found (resolve-toolchain))
        (set cxx (toolchain-found 0))
        (set cc (toolchain-found 1))
        (set lld (toolchain-found 2)))

      # Ostatnia deska ratunku na systemach opartych o apt, których
      # domyślne repozytoria mają zbyt stary Clang (np. Debian stable)
      # -- oficjalny skrypt bootstrapujący apt.llvm.org (to samo co
      # ręczne `./llvm.sh 19`).
      (when (and (not (and cxx cc lld)) (have? "apt-get"))
        (eprint "recipe.janet: nadal brak Clang/LLVM >= " MIN-CLANG " -- próbuję apt.llvm.org (llvm.sh)...")
        (when (try-run "curl -fsSL -o /tmp/zpk-llvm.sh https://apt.llvm.org/llvm.sh && chmod +x /tmp/zpk-llvm.sh")
          (try-run (string (sudo-) "/tmp/zpk-llvm.sh " MIN-CLANG)))
        (set toolchain-found (resolve-toolchain))
        (set cxx (toolchain-found 0))
        (set cc (toolchain-found 1))
        (set lld (toolchain-found 2)))

      (unless (and cxx cc lld)
        (fail (string "nie udało się zapewnić Clang/LLVM >= " MIN-CLANG " + LLD -- zainstaluj ręcznie (pakiet 'clang'/'lld' albo apt.llvm.org) i uruchom ponownie")))

      # Symlinki bez numeru wersji w shim dir -- Bazel (i inne
      # narzędzia) szukają po prostu "clang++"/"clang"/"ld.lld" w
      # PATH.
      (run (string "ln -sf \"$(command -v " cxx ")\" " tool-shim-dir "/clang++"))
      (run (string "ln -sf \"$(command -v " cc ")\" " tool-shim-dir "/clang"))
      (run (string "ln -sf \"$(command -v " lld ")\" " tool-shim-dir "/ld.lld"))
      (os/setenv "CC" cc)
      (os/setenv "CXX" cxx)

      # -----------------------------------------------------------
      # `scripts/run_bazelisk.py` (zalecany sposób budowania -- sam
      # pobiera dokładną wersję Bazela z .bazelversion) wymaga `uv`.
      # Jeśli nie da się go zapewnić, spadamy do systemowego
      # bazelisk/bazel, a w ostateczności pobieramy bazelisk
      # bezpośrednio z GitHub Releases.
      # -----------------------------------------------------------
      (defn ensure-uv []
        (unless (have? "uv")
          (eprint "recipe.janet: brak 'uv' (wymagane przez scripts/run_bazelisk.py) -- próbuję zainstalować...")
          (unless (pm-install {:apt "uv" :dnf "uv" :pacman "uv" :zypper "python3-uv" :apk "uv" :brew "uv"})
            (eprint "recipe.janet: menedżer pakietów nie ma 'uv' -- próbuję oficjalnego instalatora (astral.sh)...")
            (try-run "curl -LsSf https://astral.sh/uv/install.sh | sh")
            (def uv-bin-dir (string (os/getenv "HOME") "/.local/bin"))
            (when (os/stat (string uv-bin-dir "/uv") :mode)
              (os/setenv "PATH" (string uv-bin-dir ":" (os/getenv "PATH"))))))
        (have? "uv"))

      (def uv-ok (ensure-uv))

      (def bazel-cmd
        (cond
          (and uv-ok (os/stat (string src-dir "/scripts/run_bazelisk.py") :mode))
            (string src-dir "/scripts/run_bazelisk.py")
          (have? "bazelisk") "bazelisk"
          (have? "bazel")
            (do
              (eprint "recipe.janet: uwaga -- brak 'uv', używam systemowego 'bazel' zamiast scripts/run_bazelisk.py; wersja Bazela może się nie zgadzać z .bazelversion")
              "bazel")
          (do
            (eprint "recipe.janet: brak bazel/bazelisk -- pobieram bazelisk z GitHub Releases...")
            (def arch-out (shell-out "uname -m"))
            (def arch (arch-out 1))
            (def bazelisk-arch (if (= arch "aarch64") "arm64" "amd64"))
            (def dest (string tool-shim-dir "/bazel"))
            (run (string "curl -fsSL -o " dest
                         " https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-" bazelisk-arch
                         " && chmod +x " dest))
            "bazel")))

      # Budujemy driver toolchaina ("carbon") -- wymagany. Zbudowanie
      # //toolchain jako efekt uboczny materializuje
      # bazel-bin/toolchain/install/prefix_root -- gotowe drzewo
      # instalacyjne z układem bin/ + lib/carbon/core (tak samo jak
      # zwykły prefiks /usr), którego binarka `carbon` używa do
      # znalezienia preludium standardowej biblioteki po ścieżce
      # względnej "../../lib/carbon" -- patrz carbon-lang#4208,
      # carbon-lang#4288. Ten pierwszy fetch/build też pobiera
      # LLVM ze źródeł jako zależność Bazela -- bywa długi, to
      # normalne, nie tylko dla tego builda.
      (run (string "cd " src-dir " && " bazel-cmd " build //toolchain"))

      # `//explorer` bywał obecny/nieobecny w zależności od stanu
      # trunku (starszy interpreter demo, stopniowo wypierany przez
      # sam toolchain) -- budujemy go najlepszym wysiłkiem i NIE
      # failujemy całej recipe, jeśli target akurat nie istnieje w tej
      # rewizji.
      (unless (try-run (string "cd " src-dir " && " bazel-cmd " build //explorer"))
        (eprint "recipe.janet: uwaga -- //explorer nie zbudowano (prawdopodobnie nie istnieje w tej rewizji trunku) -- pomijam carbon-explorer w pakiecie"))

      (def bazel-bin-result (shell-out (string "cd " src-dir " && " bazel-cmd " info bazel-bin")))
      (unless (bazel-bin-result 0)
        (fail "'bazel info bazel-bin' nie powiodło się"))
      (bazel-bin-result 1))))

(def prefix-root (string bazel-bin-dir "/toolchain/install/prefix_root"))
(unless (os/stat prefix-root :mode)
  (fail (string "nie znaleziono zbudowanego drzewa instalacyjnego: " prefix-root
                " -- upewnij się, że `bazel build //toolchain` zakończyło się sukcesem")))

(def usr-dir (string stage "/usr"))
(ensure-dir stage)
(ensure-dir-p usr-dir)

# `-L` żeby zamienić dowiązania symboliczne bazel-bin (które wskazują
# do execroot/sandboxa) na prawdziwe pliki w stage dir -- inaczej
# pakiet .zpk odziedziczyłby martwe symlinki po posprzątaniu przez
# `bazel clean`.
(run (string "cp -rL " prefix-root "/. " usr-dir "/"))
(run (string "chmod +x " usr-dir "/bin/carbon"))

# `explorer` (interpreter demo) nie wchodzi w skład prefix_root --
# instalujemy go osobno obok `carbon`, jeśli udało się go zbudować
# (patrz uwaga o //explorer powyżej).
(def explorer-src (string bazel-bin-dir "/explorer/explorer"))
(when (os/stat explorer-src :mode)
  (def dest (string usr-dir "/bin/carbon-explorer"))
  (spit dest (slurp explorer-src))
  (run (string "chmod +x " dest)))
