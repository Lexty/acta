import Testing

// Точка входа раннера тестов. В окружении CLT-only `swift test` не исполняет xctest-бандл
// (нет хост-утилиты `xctest`), поэтому прогоняем swift-testing напрямую через её публичную
// точку входа. Выход ≠ 0, если хотя бы один `@Test` упал. Запуск: `bash Scripts/test.sh`.
await Testing.__swiftPMEntryPoint() as Never
