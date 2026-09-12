# Carbon Lang packaging for Zenit Linux.

Buduje [Carbon](https://github.com/carbon-language/carbon-lang) (`carbon` --
driver toolchaina, oraz `carbon-explorer` -- interpreter demo) wprost ze
źródeł i pakuje jako `.zpk` dla Zenit Linux.

## Wymagania budowania

* [Bazelisk](https://github.com/bazelbuild/bazelisk) (albo zwykły
  `bazel` -- recipe wykrywa co jest dostępne) -- Carbon jest budowany
  wyłącznie Bazelem.
* Clang/LLVM >= 19, LLD, libc++ (`libc++-dev`, `libc++abi-dev`, `lld`
  na Debianie/Ubuntu -- patrz
  [dokumentacja narzędzi kontrybucyjnych Carbon](https://github.com/carbon-language/carbon-lang/blob/trunk/docs/project/contribution_tools.md)).
* `git`.

## Użycie

```
cd packaging/zenit
zpk validate
zpk build --verbose
zpk verify out/carbon-lang-0.0.0-trunk-x86_64.zpk
```

Budowanie kompiluje cały toolchain Bazelem, co jest ciężkie (LLVM jako
zależność) i potrafi trwać długo przy pierwszym uruchomieniu.

## Zmienne środowiskowe

* `CARBON_LANG_REF` -- gałąź/tag/commit do zbudowania (domyślnie
  `trunk`). Ustaw na konkretny SHA dla reprodukowalnych buildów.
* `ZPK_PACKAGING_SRC_DIR` -- ścieżka do już sklonowanego/przypiętego
  checkoutu carbon-lang -- pomija klonowanie.
* `ZPK_PACKAGING_PREBUILT_BAZEL_BIN` -- ścieżka do katalogu
  `bazel-bin` z wynikiem wcześniejszego `bazel build //toolchain
  //explorer //toolchain/install:carbon_toolchain_tar` (np. osobny
  krok w CI) -- pomija budowanie. Uwaga: sam `//toolchain` nie
  wystarczy, patrz sekcja niżej.

## Co trafia do pakietu

`//toolchain` sam w sobie to dziś tylko alias na driver `carbon`
(`bazel run //toolchain`) -- nie materializuje żadnego gotowego
drzewa instalacyjnego. Zamiast tego budujemy
`//toolchain/install:carbon_toolchain_tar`, archiwum `pkg_tar` z
układem `bin/` + `lib/carbon/core/...` (Carbon szuka preludium
standardowej biblioteki po ścieżce względnej wobec binarki, więc ten
układ musi zostać zachowany). Rozpakowujemy je (z pominięciem
katalogu wersji na szczycie archiwum) jako `usr/` w pakiecie, plus
osobno `carbon-explorer` (interpreter demo, `//explorer`, nie wchodzi
w skład archiwum instalki).

## Znane ograniczenia

Carbon nie publikuje jeszcze stabilnego ABI ani wydań -- ta recipe
odzwierciedla stan projektu z chwili napisania (układ archiwum
instalki opisany w `toolchain/install/BUILD` i
`install_filegroups.bzl`; poprzedni układ oparty o katalog
`bazel-bin/toolchain/install/prefix_root`, opisany w carbon-lang#4208
i #4288, został przez projekt zastąpiony tym archiwum). Nazwy
targetów Bazela mogą się zmienić wraz z rozwojem projektu -- jeśli
`bazel build //toolchain //explorer
//toolchain/install:carbon_toolchain_tar` przestanie działać,
sprawdź aktualne instrukcje w
[README carbon-lang](https://github.com/carbon-language/carbon-lang#readme).
