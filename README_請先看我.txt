TMU 口腔衛生學系 AI 虛擬病人｜MVP 起始包
========================================

這個版本只做一件事：
讓學生用瀏覽器跟一位「固定病例設定的 AI 病人」進行自由問診。

檔案說明
--------
1. streamlit_app.py
   網頁主程式。第一階段原則上不用修改。

2. case01.json
   病例設定檔。日後您最常修改的就是這一個檔案。

3. requirements.txt
   告訴 Streamlit 要安裝哪些 Python 套件。

4. .streamlit/secrets.toml.example
   API Key 格式範例。真正的 Key 不要上傳到公開 GitHub。

推薦做法：完全不安裝 Python
--------------------------
A. 建立 GitHub 帳號
B. 到 Streamlit Community Cloud，用 GitHub 登入
C. 建立 Blank app，並選擇使用 GitHub Codespaces
D. 將本起始包中的：
   - streamlit_app.py
   - case01.json
   - requirements.txt
   上傳到該 GitHub repository
E. 在 Streamlit App Settings → Secrets 中加入：
   OPENAI_API_KEY = "你的 OpenAI API Key"
F. Deploy / Reboot app
G. 瀏覽器出現「TMU 口腔衛生學系 AI 虛擬病人」即成功

重要安全原則
------------
- 第一版只用 synthetic case（合成病例）。
- 不要輸入真實姓名、病歷號、身分證字號、完整生日等可識別資訊。
- API Key 絕對不要直接寫在 streamlit_app.py。
- API Key 不要貼到公開 GitHub。
- 正式教學前，請先由教師自己測試至少 20~30 種不同問法。

第一階段驗收
------------
請用學生身分測試以下問題：

1. 阿姨您好，今天主要是哪裡不舒服？
2. 這個情況多久了？
3. 平常有什麼慢性病嗎？
4. 有固定吃什麼藥嗎？
5. 平常一天刷幾次牙？
6. 有沒有使用牙線或牙間刷？
7. 刷牙會流血嗎？
8. 有抽菸、喝酒或嚼檳榔嗎？
9. 最近一次看牙是什麼時候？
10. 嘴巴乾的情況晚上會比較嚴重嗎？

驗收重點：
- 沒問到的資料，病人不應主動全部講出來。
- 病人不能替學生做診斷。
- 病人不能突然變成老師。
- 回答應像真人，不能每次都列一大串專業知識。

完成這一步後，第二階段再加入：
1. 「臨床教師」按鈕，提供口內檢查/牙周紀錄/照片。
2. 「結束問診並評分」按鈕。
3. 評分 Rubric。
4. 第二位病例。
5. 教師端結果紀錄。
