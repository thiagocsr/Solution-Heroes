/**
 * Single source of "today" for the renewal domain.
 *
 * Date.today() cannot be mocked in Apex, which makes calendar-sensitive logic
 * (month/year boundaries, leap years) impossible to test deterministically.
 * All renewal code reads the current date through this class so tests can pin
 * a reference date via the @TestVisible override.
 *
 * Date.today() is evaluated in the running user's time zone. Because every
 * renewal field is a Date (not a DateTime), no further time zone conversion
 * is required.
 */
public inherited sharing class DateProvider {
    @TestVisible
    private static Date todayOverride;

    public static Date today() {
        return todayOverride != null ? todayOverride : Date.today();
    }
}
