# Sentinel Hub API Configuration Guide

This guide explains how to set up Sentinel Hub API access for LidarExplorer to fetch real satellite imagery data.

## Why Configure Sentinel Hub?

The multi-source validation system uses Sentinel-2 satellite imagery to:
- Calculate NDVI (vegetation health)
- Detect modern construction vs. natural terrain
- Classify terrain types (artificial, vegetation, water, etc.)
- Filter out false positives from feature detection

**Without configuration**: The app works but uses conservative fallback estimates instead of real satellite data.

**With configuration**: The app fetches real, accurate pixel values for much better validation accuracy.

## Free Tier Access

The **Copernicus Data Space Ecosystem** provides generous free tier access:
- ✅ **Completely free** (no credit card required)
- ✅ **12TB/month** transfer limit
- ✅ **Unlimited** requests (within reasonable use)
- ✅ **Global** Sentinel-2 coverage
- ✅ **Updated** every 5 days

More than enough for this app's usage! [Learn more](https://dataspace.copernicus.eu/)

---

## Setup Steps (5 minutes)

### Step 1: Create Free Account

1. Visit [https://dataspace.copernicus.eu/](https://dataspace.copernicus.eu/)
2. Click **"Sign Up"** or **"Register"**
3. Fill in your details (name, email, password)
4. Verify your email address
5. Log in to your account

### Step 2: Create OAuth Client

1. Once logged in, go to **User Settings** (usually in top-right menu)
2. Navigate to **OAuth Clients** section
3. Click **"Create New OAuth Client"**
4. Fill in the form:
   - **Client Name**: `LidarExplorer` (or any name you prefer)
   - **Grant Type**: `Client Credentials`
   - **Redirect URI**: Leave blank (not needed for client credentials)
5. Click **"Create"**

### Step 3: Copy Credentials

After creating the OAuth client, you'll see:
- **Client ID**: A long string like `sh-12345678-abcd-...`
- **Client Secret**: Another long string (show/copy it)

⚠️ **IMPORTANT**: Save both strings somewhere safe! The secret is only shown once.

### Step 4: Configure LidarExplorer

You have **two options** to configure credentials:

#### Option A: Environment Variables (Recommended for Development)

1. Open Xcode
2. Select **Product → Scheme → Edit Scheme...**
3. Select **Run** on the left
4. Go to **Arguments** tab
5. Under **Environment Variables**, add:
   ```
   Name: COPERNICUS_CLIENT_ID
   Value: [paste your Client ID]

   Name: COPERNICUS_CLIENT_SECRET
   Value: [paste your Client Secret]
   ```
6. Click **Close**

#### Option B: Secrets Configuration File (Recommended for Production)

1. Create a file named `Secrets.xcconfig` in the project root
2. Add your credentials:
   ```xcconfig
   COPERNICUS_CLIENT_ID = sh-12345678-abcd-...
   COPERNICUS_CLIENT_SECRET = your-secret-here
   ```
3. Update `SatelliteImageryService.swift` to read from xcconfig:
   ```swift
   private func loadCredentials() {
       #if DEBUG
       clientId = ProcessInfo.processInfo.environment["COPERNICUS_CLIENT_ID"]
       clientSecret = ProcessInfo.processInfo.environment["COPERNICUS_CLIENT_SECRET"]
       #else
       // For release builds, load from secure storage
       clientId = Bundle.main.object(forInfoDictionaryKey: "COPERNICUS_CLIENT_ID") as? String
       clientSecret = Bundle.main.object(forInfoDictionaryKey: "COPERNICUS_CLIENT_SECRET") as? String
       #endif
   }
   ```
4. **IMPORTANT**: Make sure `Secrets.xcconfig` is in `.gitignore` (it already is!)

### Step 5: Verify Setup

1. Build and run the app
2. Navigate to a location and trigger feature analysis
3. Check Xcode console logs for:
   ```
   ✅ "Successfully authenticated with Copernicus"
   ✅ "Successfully extracted real Sentinel-2 pixel values"
   ```

If you see these messages, you're all set! 🎉

If you see warnings about "OAuth credentials not configured", go back and check Steps 3-4.

---

## Troubleshooting

### "OAuth authentication failed"

**Cause**: Invalid credentials or expired client secret

**Solution**:
1. Double-check you copied the Client ID and Secret correctly
2. Make sure there are no extra spaces or line breaks
3. Try creating a new OAuth client and using those credentials

### "Sentinel Hub API error: HTTP 401"

**Cause**: Access token expired or invalid

**Solution**: The app should auto-refresh tokens. If this persists:
1. Check that your Copernicus account is still active
2. Verify your OAuth client hasn't been deleted
3. Try logging out and back in to Copernicus

### "Sentinel Hub API error: HTTP 429"

**Cause**: Rate limit exceeded (very rare with free tier)

**Solution**:
1. The app caches results for 24 hours, so this shouldn't happen
2. Wait a few minutes and try again
3. Check you haven't exceeded 12TB/month (unlikely for normal usage)

### "Cloudy or invalid pixel detected"

**Cause**: Recent satellite image has clouds over your location

**Solution**: This is normal! The app will automatically try older images (up to 30 days back). If all recent images are cloudy, the app falls back to estimated values.

### "Using fallback mode with limited functionality"

**Cause**: Credentials not configured

**Solution**: Follow Steps 1-4 above to configure your OAuth credentials

---

## Security Best Practices

### ✅ DO:
- Store credentials in environment variables or `.xcconfig` files
- Add `Secrets.xcconfig` to `.gitignore`
- Rotate your Client Secret periodically (every 3-6 months)
- Use different credentials for development vs. production

### ❌ DON'T:
- Commit credentials to Git
- Share your Client Secret publicly
- Hardcode credentials in source code
- Use the same credentials across multiple apps

---

## API Usage & Limits

### Free Tier Quotas (per month)

- **Transfer**: 12TB (resets monthly)
- **Requests**: Unlimited (within reasonable use)
- **Processing Units**: Generous allocation
- **Coverage**: Global (any location worldwide)

### Typical Usage

For LidarExplorer, each feature detection request:
- Fetches ~1KB of data (4 band values)
- Cached for 24 hours
- Typical user: ~100 detections/day = ~3MB/day = ~90MB/month

**Result**: You'll use <0.001% of your free tier quota! 🎉

### Monitoring Usage

1. Log in to [Copernicus Data Space Ecosystem](https://dataspace.copernicus.eu/)
2. Go to **Dashboard** or **Usage Statistics**
3. View your monthly quota usage

---

## Advanced Configuration

### Adjusting Caching

In `SatelliteImageryService.swift`, you can adjust cache duration:

```swift
private let cacheExpirationSeconds: TimeInterval = 86400 // 24 hours (default)

// For more aggressive caching (less API calls):
private let cacheExpirationSeconds: TimeInterval = 604800 // 7 days

// For fresh data (more API calls):
private let cacheExpirationSeconds: TimeInterval = 3600 // 1 hour
```

### Adjusting Time Range

By default, the app looks for images from the last 30 days. To change:

```swift
// In fetchFromSentinelHub method:
"timeRange": [
    "from": getRecentDate(daysAgo: 30), // Change this number
    "to": getCurrentDate()
]
```

### Adjusting Cloud Threshold

By default, the app accepts images with up to 50% cloud coverage:

```swift
"maxCloudCoverage": 50 // Change to 20 for clearer images (but less availability)
```

---

## Support & Resources

### Official Documentation

- [Copernicus Data Space Ecosystem](https://dataspace.copernicus.eu/)
- [Sentinel Hub API Docs](https://documentation.dataspace.copernicus.eu/)
- [Sentinel-2 Mission Info](https://documentation.dataspace.copernicus.eu/Data/SentinelMissions/Sentinel2.html)

### Getting Help

1. **Copernicus Support**: [Forum](https://forum.dataspace.copernicus.eu/)
2. **LidarExplorer Issues**: [GitHub Issues](https://github.com/ehurrn/LidarExplorer/issues)
3. **API Status**: Check [Copernicus Status Page](https://dataspace.copernicus.eu/)

---

## FAQ

**Q: Is this really free?**
A: Yes! The Copernicus program is funded by the European Union and provides free access to Sentinel data.

**Q: Do I need a credit card?**
A: No! Registration is completely free with just an email address.

**Q: Can I use this commercially?**
A: Yes! Copernicus data is open and free for any use (commercial or non-commercial).

**Q: What if I exceed the quota?**
A: Very unlikely with this app's usage. If you do, you'll get throttled (not charged). Quota resets monthly.

**Q: How recent is the satellite data?**
A: Sentinel-2 satellites pass over every location every 5 days. The app fetches the most recent cloud-free image.

**Q: What resolution is the data?**
A: 10 meters for the bands we use (B02, B03, B04, B08). More than enough for terrain classification!

**Q: Can I use this offline?**
A: Once fetched, satellite data is cached for 24 hours. But you need internet for the initial fetch.

---

**Last Updated**: 2026-01-22
**Document Version**: 1.0
