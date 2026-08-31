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

(defn shell-out [cmd]
  # Jak `run`, ale zwraca przechwycone stdout (przycięte) zamiast tylko
  # kodu wyjścia -- potrzebne do `bazel info bazel-bin`.
  (def proc (os/spawn ["/bin/sh" "-c" cmd] :p {:out :pipe}))
  (def out (:read (proc :out) :all))
  (def code (:wait proc))
  (unless (zero? code)
    (fail (string "'" cmd "' zakończone kodem " code)))
  (string/trimr (or out "")))

(defn ensure-dir [path]
  (try (os/mkdir path) ([_] nil)))

(defn ensure-dir-p [path]
  (var acc "")
  (each part (string/split "/" path)
    (when (> (length part) 0)
      (set acc (string acc "/" part))
      (ensure-dir acc))))

# ---------------------------------------------------------------------
# Carbon nie ma tagowanych wydań (patrz komentarz w zpk.build) -- nie
# ma więc "źródła" do pobrania w postaci tarballa releasu. Ta recipe
# klonuje repo samodzielnie, chyba że operator już ma checkout gotowy
# (ZPK_PACKAGING_SRC_DIR) -- np. w CI, gdzie sklonowanie i ewentualne
# przypięcie konkretnego commita robi osobny, wcześniejszy krok.
# ---------------------------------------------------------------------

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

# ---------------------------------------------------------------------
# Zależności budowania -- Carbon wymaga Bazela (przez bazelisk, żeby
# dostać dokładnie skonfigurowaną wersję -- patrz .bazelversion w
# repo), Clang/LLVM >= 19, LLD i libc++. Same sprawdzamy tylko
# obecność narzędzi -- instalacja pakietów systemowych to zadanie
# `depends_on`/zewnętrznego środowiska budowania, nie tej recipe.
# ---------------------------------------------------------------------

(defn require-tool [tool hint]
  (def code (os/shell (string "command -v " tool " >/dev/null 2>&1")))
  (unless (zero? code)
    (fail (string "brak '" tool "' w PATH -- " hint))))

(def bazel-cmd
  (if (zero? (os/shell "command -v bazelisk >/dev/null 2>&1"))
    "bazelisk"
    (if (os/stat (string src-dir "/scripts/run_bazelisk.py") :mode)
      (string src-dir "/scripts/run_bazelisk.py")
      "bazel")))

(require-tool "clang++" "zainstaluj Clang/LLVM >= 19 (apt.llvm.org / Homebrew)")
(require-tool "ld.lld" "zainstaluj LLD (pakiet 'lld')")

(def prebuilt (os/getenv "ZPK_PACKAGING_PREBUILT_BAZEL_BIN"))

(def bazel-bin-dir
  (if (and prebuilt (> (length prebuilt) 0))
    # CI/operator już zbudowało toolchain wcześniej w tym samym biegu
    # (np. osobny krok `bazel build //toolchain //explorer`) -- nie
    # buduj drugi raz, użyj gotowego katalogu bazel-bin.
    prebuilt
    (do
      # Budujemy driver toolchaina ("carbon") i explorer. Zbudowanie
      # //toolchain jako efekt uboczny materializuje
      # bazel-bin/toolchain/install/prefix_root -- gotowe drzewo
      # instalacyjne z układem bin/ + lib/carbon/core (tak samo jak
      # zwykły prefiks /usr), którego binarka `carbon` używa do
      # znalezienia preludium standardowej biblioteki po ścieżce
      # względnej "../../lib/carbon" -- patrz carbon-lang#4208,
      # carbon-lang#4288.
      (run (string "cd " src-dir " && " bazel-cmd " build //toolchain //explorer"))
      (shell-out (string "cd " src-dir " && " bazel-cmd " info bazel-bin")))))

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
# instalujemy go osobno obok `carbon`.
(def explorer-src (string bazel-bin-dir "/explorer/explorer"))
(when (os/stat explorer-src :mode)
  (def dest (string usr-dir "/bin/carbon-explorer"))
  (spit dest (slurp explorer-src))
  (run (string "chmod +x " dest)))
