{
  lib,
  buildNpmPackage,
  fetchurl,
  writeText,
  ...
}:
let
  notoSansMono = fetchurl {
    name = "NotoSansMono.ttf";
    url = "https://raw.githubusercontent.com/notofonts/notofonts.github.io/noto-monthly-release-2026.08.01/fonts/NotoSansMono/unhinted/variable-ttf/NotoSansMono%5Bwdth%2Cwght%5D.ttf";
    hash = "sha256-BLG//8WYEU+ZjGDzE/emTfbJEez+1Hok4n8Dsd80v2Y=";
  };

  sourceSerif = fetchurl {
    name = "SourceSerif4Variable-Roman.otf";
    url = "https://raw.githubusercontent.com/adobe-fonts/source-serif/4.005R/VAR/SourceSerif4Variable-Roman.otf";
    hash = "sha256-hntzxqlUpKZGFpBtF5+UVyp0h5Ch0CLr7v8H9W6gIho=";
  };

  notoSerifSC = fetchurl {
    name = "NotoSerifSC-VF.otf";
    url = "https://raw.githubusercontent.com/notofonts/noto-cjk/Serif2.003/Serif/Variable/OTF/Subset/NotoSerifSC-VF.otf";
    hash = "sha256-cbTT3tLZD/Q7t1pOSM2+Fw8LjVSG3In/h/KhcotW2mQ=";
  };

  jetBrainsMono = fetchurl {
    name = "JetBrainsMono.ttf";
    url = "https://raw.githubusercontent.com/JetBrains/JetBrainsMono/v2.304/fonts/variable/JetBrainsMono%5Bwght%5D.ttf";
    hash = "sha256-ZioZbVjxGDvy13QottUoP+P0UWGrAhvqQDa8mOXKwBY=";
  };

  geist = fetchurl {
    name = "Geist.ttf";
    url = "https://raw.githubusercontent.com/vercel/geist-font/v1.7.2/fonts/Geist/variable/Geist%5Bwght%5D.ttf";
    hash = "sha256-c4lOBEjK6QqStsL4cyt7uay3uUxBi/9Vna1KGOHellk=";
  };

  localFontsPatch = writeText "ompweb-local-fonts.patch" ''
    diff --git a/app/layout.tsx b/app/layout.tsx
    --- a/app/layout.tsx
    +++ b/app/layout.tsx
    @@ -1,45 +1,46 @@
     import type { Metadata, Viewport } from "next";
     import Script from "next/script";
    -import { Geist, JetBrains_Mono, Noto_Sans_Mono, Noto_Serif_SC, Source_Serif_4 } from "next/font/google";
    +import localFont from "next/font/local";
     import { ThemeColor } from "@/hooks/useTheme";
     import { IosFocusZoomGuard } from "@/components/IosFocusZoomGuard";
     import { SIDEBAR_HISTORY_BRIDGE_SCRIPT } from "@/lib/sidebar-history-bridge";
     import "./globals.css";

    -const geist = Geist({
    -  subsets: ["latin"],
    +const geist = localFont({
    +  src: "./fonts/Geist.ttf",
    +  weight: "100 900",
       variable: "--font-geist",
       display: "swap",
     });

    -const jetbrainsMono = JetBrains_Mono({
    -  subsets: ["latin"],
    -  weight: ["400", "500", "600"],
    +const jetbrainsMono = localFont({
    +  src: "./fonts/JetBrainsMono.ttf",
    +  weight: "100 800",
       variable: "--font-jb-mono",
       display: "swap",
     });

    -const notoSansMono = Noto_Sans_Mono({
    -  subsets: ["latin", "cyrillic"],
    +const notoSansMono = localFont({
    +  src: "./fonts/NotoSansMono.ttf",
    +  weight: "100 900",
       variable: "--font-noto-mono",
       display: "swap",
     });

     // Display serif pair for the warm-humanistic heading voice: Source Serif 4
     // covers latin, Noto Serif SC covers CJK. Both expose CSS variables consumed
     // by --font-serif in globals.css.
    -const sourceSerif = Source_Serif_4({
    -  subsets: ["latin"],
    +const sourceSerif = localFont({
    +  src: "./fonts/SourceSerif4Variable-Roman.otf",
    +  weight: "200 900",
       variable: "--font-source-serif",
       display: "swap",
     });

    -const notoSerifSC = Noto_Serif_SC({
    -  // CJK glyphs are served via unicode-range slices regardless of subset;
    -  // "latin" satisfies next/font's preloading requirement.
    -  subsets: ["latin"],
    -  weight: ["600", "700"],
    +const notoSerifSC = localFont({
    +  src: "./fonts/NotoSerifSC-VF.otf",
    +  weight: "200 900",
       variable: "--font-noto-serif",
       display: "swap",
     });

  '';

  productionLib = lib.fileset.difference ../lib (
    lib.fileset.fileFilter (file: lib.hasInfix ".test." file.name) ../lib
  );

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../app
      ../bin
      ../components
      ../hooks
      productionLib
      ../public
      ../scripts

      ../instrumentation.ts
      ../instrumentation.node.ts
      ../next.config.ts
      ../next-env.d.ts
      ../package.json
      ../package-lock.json
      ../postcss.config.mjs
      ../tailwind.config.ts
      ../tsconfig.json
      ../proxy.ts
    ];
  };
  version = (builtins.fromJSON (builtins.readFile ../package.json)).version;
in
buildNpmPackage (finalAttrs: {
  pname = "ompweb";
  inherit src version;

  patches = [ localFontsPatch ];

  postPatch = ''
    mkdir -p app/fonts
    cp ${notoSansMono} app/fonts/NotoSansMono.ttf
    cp ${sourceSerif} app/fonts/SourceSerif4Variable-Roman.otf
    cp ${notoSerifSC} app/fonts/NotoSerifSC-VF.otf
    cp ${jetBrainsMono} app/fonts/JetBrainsMono.ttf
    cp ${geist} app/fonts/Geist.ttf
  '';

  npmDepsHash = "sha256-HxT+m6bI0I3t9sqsSgHun6oXve3WtIEmkFpCoBplrC4=";

  # npmPackFlags = [ "--ignore-scripts" ];

  meta = {
    description = "Local web UI for the oh-my-pi (omp) coding agent";
    license = lib.licenses.mit;
  };
})
