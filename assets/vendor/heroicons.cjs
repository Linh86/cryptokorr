// Heroicons Tailwind plugin — exposes `hero-#{ICON}` utility classes
// pulling from `deps/heroicons/optimized` (Hex dep). Each class
// renders the SVG via a CSS mask so the icon inherits `currentColor`.
//
// Tailwind v4 plugin format: a single function that receives the
// plugin API. The v3-style `require("tailwindcss/plugin")` wrapper
// doesn't resolve under the standalone v4 binary (no node_modules
// tailwindcss), and we can't ship one because package.json sets
// "type":"module" — so this file is .cjs and exports the function
// directly.
const fs = require("fs")
const path = require("path")

module.exports = {
  handler: function ({ matchComponents, theme }) {
    const iconsDir = path.join(__dirname, "../../deps/heroicons/optimized")
    const values = {}
    const icons = [
      ["", "/24/outline"],
      ["-solid", "/24/solid"],
      ["-mini", "/20/solid"],
      ["-micro", "/16/solid"],
    ]
    icons.forEach(([suffix, dir]) => {
      fs.readdirSync(path.join(iconsDir, dir)).forEach((file) => {
        const name = path.basename(file, ".svg") + suffix
        values[name] = { name, fullPath: path.join(iconsDir, dir, file) }
      })
    })
    matchComponents(
      {
        hero: ({ name, fullPath }) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          content = encodeURIComponent(content)
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            mask: `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            display: "inline-block",
            width: size,
            height: size,
          }
        },
      },
      { values }
    )
  },
}
