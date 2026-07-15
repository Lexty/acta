import ActaKit

// Заготовка testTarget'а, чтобы команда `swift test` из плана проходила с самого начала.
//
// ВНИМАНИЕ: при CLT-only (полного Xcode нет) `swift test` только СОБИРАЕТ тестовый бандл, но
// НЕ исполняет его — в системе нет хост-утилиты `xctest`. Реальный прогон тестов (с падением
// при ошибке) делает executable-раннер: `bash Scripts/test.sh` (он же `swift run ActaTestRunner`).
//
// Здесь намеренно нет тест-кейсов: они живут в таргете ActaTestRunner, чтобы реально исполняться.
enum ActaTestsPlaceholder {
    static let linkedModule = AppInfo.name
}
