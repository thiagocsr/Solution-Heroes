@IsTest
private class DateProviderTest {
    @IsTest
    static void today_withoutOverride_returnsSystemToday() {
        Assert.areEqual(Date.today(), DateProvider.today(), 'Without an override the system date must be used');
    }

    @IsTest
    static void today_withOverride_returnsPinnedDate() {
        Date pinned = Date.newInstance(2028, 2, 29);
        DateProvider.todayOverride = pinned;

        Assert.areEqual(pinned, DateProvider.today(), 'The pinned reference date must be returned');
    }
}
