# ObjectSizeLock v0.9 – 追蹤連續性診斷修正

## 變更
- Vision 原始框在低信心時仍呈現（幾何有效時）；低信心不再讓原始框消失。
- 幾何無效不是單幀就 LOST，而是連續 24 個異常處理影格才停止追蹤。
- 相似度/初始影像紋理不足不會在第一幀直接判 LOST；外觀相似度僅供診斷。
- 降低短暫信心波動造成的誤拒絕，放寬相鄰影格尺度和位移跳變門檻。
- 仍禁止自動變焦、仍未實作可靠遮擋後重辨識。這不是 LiteTrack/OSTrack/CoreML 版本。

## 安裝補丁（已使用 v0.8 的專案）

```bash
cd /home/mark/mark_gitlab/ObjectSizeLock_iOS
unzip -o ../ObjectSizeLock_v09_diagnostic_patch.zip
git diff --check
git add Sources/CameraTracker.swift Sources/ContentView.swift README_V09.md
git commit -m "fix: buffer invalid Vision observations and expose raw boxes"
git push origin main
git push github main
```

GitHub Actions 成功後下載新的 IPA artifact，Ubuntu iloader Import IPA 安裝。

## 測試
1. Auto Zoom 保持關閉，選取完整目標。
2. 在靜止、緩慢移動、遠近變化下，觀察粉紅色 Vision 框與綠框。
3. 如果粉紅框就追錯，問題在 Vision/初始化/影像座標；如果粉紅框對、綠框錯，問題在額外檢查。
4. 給我們保留螢幕錄影與相機影片（最好有相同時間點），並附 Xcode/系統 Log（若可取得）。

## 測試狀態
- Swift parser：通過（Linux swiftc -frontend -parse）。
- Xcode iOS 編譯、iPhone 實機 Vision、Re-ID、Auto Zoom：未測試／未驗證。
