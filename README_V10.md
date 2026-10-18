# ObjectSizeLock v1.0 實驗性追蹤改善

本版從 v0.9 修改 CameraTracker.swift 與 ContentView.swift：

- Vision 追蹤節流由約 12.5 Hz 改為最多 25 Hz，實際速率依裝置負載而定。
- 持續低信心或追蹤異常時，在最後可信框附近最多重新初始化兩次 Vision 追蹤請求。
- 恢復前顯示 RECOVERING，不將該過程當作已辨識同一個物件。
- 自動 Zoom 仍關閉；避免錯追時放大。
- 保留診斷用粉紅、綠、黃色框。

**注意：尚未加入 AI 模型、沒有全畫面 Re-ID、無法保證遮擋後找回同一物件。**

將 ZIP 解壓縮至 ObjectSizeLock_iOS 根目錄，覆蓋兩個 Sources/*.swift 檔，推送 GitHub Actions 編譯。Linux 可檢查 Swift 語法，但無法編譯 iOS SDK 或驗證 Vision。
