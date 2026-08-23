// Shared flat ESLint config for all Tessera TypeScript workspaces.
// Type-aware linting is intentionally left off here to keep `pnpm lint` fast and
// project-config-free; correctness is enforced by `tsc` in the typecheck task.
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";
import prettier from "eslint-config-prettier";

export default tseslint.config(
  {
    ignores: [
      "**/dist/**",
      "**/.next/**",
      "**/out/**",
      "**/coverage/**",
      "**/node_modules/**",
      // Static Claude Design mockups — the visual contract, not app source.
      "**/design/**",
      "**/*.d.ts",
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 2023,
      sourceType: "module",
      globals: {
        ...globals.node,
        ...globals.es2023,
      },
    },
    rules: {
      // Golden rule: no `any`. Fix the type instead.
      "@typescript-eslint/no-explicit-any": "error",
      // NOTE: `consistent-type-imports` is intentionally OFF. It runs without type info and
      // flags NestJS DI-injected classes (ConfigService, PrismaService, …) as type-only;
      // applying its fix would strip the runtime import that `emitDecoratorMetadata` needs.
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_", ignoreRestSiblings: true },
      ],
      "no-console": "off",
    },
  },
  // Config files may use CommonJS + require().
  {
    files: ["**/*.cjs"],
    languageOptions: { sourceType: "commonjs" },
    rules: { "@typescript-eslint/no-require-imports": "off" },
  },
  prettier,
);
