import Testing
import ActaKit

// Заготовка: доказывает, что тестовый раннер реально исполняет тесты и падает при ошибке.
// Содержательные юнит-тесты (аргументы ffmpeg, логика восстановления, детектор «данные не
// текут», slug/front-matter) добавляются в Task 2–5 рядом, в этом же таргете.
@Test
func bundleIdentifierIsStable() {
    #expect(AppInfo.bundleID == "dev.personal.acta")
}

@Test
func appNameIsActa() {
    #expect(AppInfo.name == "Acta")
}
