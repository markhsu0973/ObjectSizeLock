# ObjectSizeLock v0.6 — 診斷版

本版目的：分辨 Vision 追蹤框漂移與外觀驗證誤判，**不是已驗證穩定的任意物件追蹤器**。

## 修改
- 24x24 灰階相似度改為診斷資訊，不再連續兩次不通過就 LOST。
- 仍在相似度不佳、追蹤框異常、Vision 信心低時停止自動 Zoom。
- 顯示 Vision confidence、模板相似度、Vision normalized box 與不符幀數。
- 追蹤框單次跳動不會立即 LOST；連續異常才停止。
- 預設 Auto Zoom 關閉。
- 沿用 v0.5 的模板搜尋和重新鎖定邏輯，尚未驗證可準確 Re-ID。

## 在 Ubuntu 安裝修正檔
```bash
cd /home/mark/mark_gitlab/ObjectSizeLock_iOS
unzip -o ../ObjectSizeLock_v06_diagnostic_patch.zip
git diff --check
git diff --stat
git add Sources/CameraTracker.swift Sources/ContentView.swift
git commit -m 'diagnostic: expose vision tracking and avoid premature appearance loss'
git push origin main
git push github main
```

在 GitHub Actions 確認編譯成功後下載新的 Artifact，透過 iloader 更新。

## 實機驗證
1. Auto Zoom 保持關閉，用指頭框選桌面物件後移開手。
2. 觀察綠框與 `Vision`、`相似`、`Box` 是否吻合。
3. 當相似度低於 0.60 時，留意綠框是否仍追對物件。
4. 緩慢遮擋後再次露出，記錄 LOST、REACQUIRED? 狀態是否正確。
5. 螢幕錄影並分享，以判斷下一步是否要修正相機方位映射，或更換追蹤模型。

## 驗證狀態
- Linux Swift frontend parse：通過。
- Xcode / Apple SDK typecheck：未執行。
- GitHub Actions build：未執行。
- iPhone 實機 / 任意物件追蹤準確度：未測試。
- 先前影片的灰階相似度敏感度實驗，不能當作 v0.6 全流程通過證據。
