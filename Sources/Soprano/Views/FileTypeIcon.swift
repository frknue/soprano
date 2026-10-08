import Foundation

/// SF Symbol for an explorer row. Follows Orca's lucide tables: an exact
/// lowercase filename first, then `.env*` / `Dockerfile*` / `Makefile*`, then
/// the (compound-aware) extension, else a plain document.
enum FileTypeIcon {
    static let folder = "folder"
    static let openFolder = "folder.fill"
    static let symlink = "link"
    static let file = "doc"

    private enum Kind: String {
        case archive = "doc.zipper"
        case box = "shippingbox"
        case braces = "curlybraces.square"
        case chart = "chart.bar.doc.horizontal"
        case code = "chevron.left.forwardslash.chevron.right"
        case cog = "doc.badge.gearshape"
        case cube = "cube"
        case database = "cylinder"
        case diff = "plus.forwardslash.minus"
        case image = "photo"
        case json = "curlybraces"
        case key = "key"
        case lock = "lock.doc"
        case music = "music.note"
        case sliders = "slider.horizontal.3"
        case spreadsheet = "tablecells"
        case terminal = "apple.terminal"
        case text = "doc.text"
        case type = "textformat"
        case video = "film"
    }

    static func symbolName(forFileNamed name: String) -> String {
        let lowerName = name.lowercased()
        if let kind = byName[lowerName] {
            return kind.rawValue
        }
        if lowerName == ".env" || lowerName.hasPrefix(".env.") {
            return Kind.lock.rawValue
        }
        if lowerName == "dockerfile" || lowerName.hasPrefix("dockerfile.") {
            return Kind.cog.rawValue
        }
        if lowerName == "makefile" || lowerName.hasPrefix("makefile.") {
            return Kind.terminal.rawValue
        }
        return byExtension[pathExtension(of: lowerName)]?.rawValue ?? file
    }

    private static let compoundExtensions = ["tar.bz2", "tar.gz", "tar.xz"]

    private static func pathExtension(of lowerName: String) -> String {
        if let compound = compoundExtensions.first(where: { lowerName.hasSuffix(".\($0)") }) {
            return compound
        }
        guard let dot = lowerName.lastIndex(of: "."),
              dot != lowerName.startIndex,
              lowerName.index(after: dot) != lowerName.endIndex
        else { return "" }
        return String(lowerName[lowerName.index(after: dot)...])
    }

    private static let byName: [String: Kind] = [
        ".babelrc": .sliders, ".dockerignore": .sliders, ".editorconfig": .sliders,
        ".eslintrc": .sliders, ".eslintrc.cjs": .sliders, ".eslintrc.js": .sliders,
        ".eslintrc.json": .json, ".eslintrc.yaml": .sliders, ".eslintrc.yml": .sliders,
        ".gitattributes": .sliders, ".gitignore": .sliders, ".npmrc": .sliders,
        ".prettierrc": .sliders, ".prettierrc.json": .json, ".prettierrc.yaml": .sliders,
        ".prettierrc.yml": .sliders, "agents.md": .text, "authors": .text,
        "bun.lock": .box, "bun.lockb": .box, "cargo.lock": .box, "cargo.toml": .box,
        "changelog": .text, "changelog.md": .text, "cmakelists.txt": .cog,
        "codeowners": .key, "components.json": .sliders, "composer.json": .box,
        "composer.lock": .box, "contributing": .text, "contributing.md": .text,
        "copying": .key, "dockerfile": .cog, "gemfile": .box, "go.mod": .box,
        "go.sum": .box, "license": .key, "makefile": .terminal, "meson.build": .cog,
        "notice": .key, "package-lock.json": .box, "package.json": .box,
        "package.swift": .box, "package.resolved": .box,
        "pipfile": .box, "pnpm-lock.yaml": .box, "pnpm-workspace.yaml": .box,
        "poetry.lock": .box, "pom.xml": .box, "postcss.config.cjs": .sliders,
        "postcss.config.js": .sliders, "postcss.config.mjs": .sliders,
        "postcss.config.ts": .sliders, "pyproject.toml": .box, "readme": .text,
        "readme.md": .text, "requirements-dev.txt": .box, "requirements.txt": .box,
        "security": .lock, "security.md": .lock, "settings.gradle": .cog,
        "settings.gradle.kts": .cog, "tailwind.config.cjs": .sliders,
        "tailwind.config.js": .sliders, "tailwind.config.mjs": .sliders,
        "tailwind.config.ts": .sliders, "todo": .text, "tsconfig.json": .sliders,
        "vite.config.js": .sliders, "vite.config.mjs": .sliders, "vite.config.ts": .sliders,
        "vitest.config.js": .sliders, "vitest.config.mjs": .sliders,
        "vitest.config.ts": .sliders, "yarn.lock": .box,
    ]

    private static let byExtension: [String: Kind] = {
        let groups: [(Kind, [String])] = [
            (.terminal, ["bash", "bat", "cmd", "fish", "nu", "ps1", "sh", "zsh"]),
            (.code, [
                "astro", "c", "cc", "cjs", "clj", "cpp", "cs", "cts", "cxx", "dart", "erl",
                "ex", "exs", "fs", "fsx", "go", "h", "hpp", "hrl", "hs", "htm", "html",
                "java", "js", "jsx", "kt", "kts", "lua", "m", "mm", "mjs", "mts", "nim",
                "php", "pl", "pm", "py", "r", "rb", "rs", "scala", "sol", "svelte", "swift",
                "ts", "tsx", "vb", "vue", "xhtml", "xml", "zig",
            ]),
            (.video, ["avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm"]),
            (.archive, [
                "7z", "br", "bz2", "dmg", "gz", "iso", "rar", "tar", "tar.bz2", "tar.gz",
                "tar.xz", "tbz2", "tgz", "txz", "xz", "zip",
            ]),
            (.cube, ["blend", "fbx", "glb", "gltf", "obj", "stl"]),
            (.key, ["asc", "cer", "crt", "gpg", "key", "pem", "pub"]),
            (.image, [
                "ai", "avif", "bmp", "eps", "gif", "heic", "icns", "ico", "jpeg", "jpg",
                "png", "psd", "svg", "tif", "tiff", "webp",
            ]),
            (.cog, ["gradle"]),
            (.text, [
                "adoc", "doc", "docx", "log", "markdown", "md", "mdx", "pdf", "qmd",
                "rmarkdown", "rmd", "rst", "rtf", "tex", "txt",
            ]),
            (.spreadsheet, ["csv", "ods", "tsv", "xls", "xlsx"]),
            (.type, ["css", "eot", "less", "otf", "sass", "scss", "ttf", "woff", "woff2"]),
            (.database, ["db", "duckdb", "prisma", "sql", "sqlite", "sqlite3"]),
            (.json, ["json", "json5", "jsonc"]),
            (.braces, ["gql", "graphql", "proto"]),
            (.chart, ["ipynb", "mmd", "ppt", "pptx"]),
            (.sliders, [
                "cfg", "conf", "hcl", "ini", "plist", "properties", "tf", "tfvars", "toml",
                "yaml", "yml",
            ]),
            (.diff, ["diff", "patch"]),
            (.music, ["aac", "flac", "m4a", "mp3", "ogg", "opus", "wav"]),
            (.lock, ["lock", "p12", "pfx"]),
        ]
        var table: [String: Kind] = [:]
        for (kind, extensions) in groups {
            for pathExtension in extensions {
                table[pathExtension] = kind
            }
        }
        return table
    }()
}
