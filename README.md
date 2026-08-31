Carbon Lang packaging for Zenit Linux.

Buduje [Carbon](https://github.com/carbon-language/carbon-lang) (`carbon` --
driver toolchaina, oraz `carbon-explorer` -- interpreter demo) wprost ze
źródeł i pakuje jako `.zpk` dla Zenit Linux.

## Dlaczego to inne niż `zde`/`hsharp`/`blue-environment`

Carbon jest projektem eksperymentalnym bez tagowanych wydań -- nie ma
tarballa źródłowego do pobrania, więc `recipe.janet` samo klonuje repo
(domyślnie gałąź `trunk`) zamiast operować na już wypakowanym drzewie
źródłowym obok `zpk.build`. Z tego samego powodu wersja pakietu to
`0.0.0-trunk`, a nie realny numer wersji projektu.

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
  //explorer` (np. osobny krok w CI) -- pomija budowanie.

## Co trafia do pakietu

Cała zawartość `bazel-bin/toolchain/install/prefix_root/` (drzewo
`bin/` + `lib/carbon/core/...` -- Carbon szuka preludium standardowej
biblioteki po ścieżce względnej wobec binarki, więc ten układ musi
zostać zachowany) trafia jako `usr/` w pakiecie, plus osobno
`carbon-explorer` (interpreter demo, `//explorer`, nie wchodzi w skład
`prefix_root`).

## Znane ograniczenia

Carbon nie publikuje jeszcze stabilnego ABI ani wydań -- ta recipe
odzwierciedla stan projektu z chwili napisania (dokumentacja
kontrybucyjna, struktura `bazel-bin/toolchain/install/prefix_root`
opisana w carbon-lang#4208 i #4288). Nazwy targetów Bazela mogą się
zmienić wraz z rozwojem projektu -- jeśli `bazel build //toolchain
//explorer` przestanie działać, sprawdź aktualne instrukcje w
[README carbon-lang](https://github.com/carbon-language/carbon-lang#readme).
