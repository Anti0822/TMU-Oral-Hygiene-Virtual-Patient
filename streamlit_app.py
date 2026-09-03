import json
from pathlib import Path

import streamlit as st
from openai import OpenAI

st.set_page_config(
    page_title="TMU 口腔衛生學系 AI 虛擬病人",
    page_icon="🦷",
    layout="centered",
)

CASE_PATH = Path(__file__).parent / "case01.json"

with open(CASE_PATH, "r", encoding="utf-8") as f:
    case = json.load(f)

st.title("🦷 TMU 口腔衛生學系 AI 虛擬病人")
st.caption("MVP 教學測試版｜請以口腔衛生專業人員身分進行問診")

with st.expander("📋 學生可見病例起始資訊", expanded=True):
    st.write(f"**病例：** {case['case_id']}｜{case['title']}")
    st.write(f"**病人：** {case['patient_name']}，{case['age']} 歲，{case['sex']}")
    st.write(f"**主訴：** {case['chief_complaint']}")
    st.info("請開始詢問病史、用藥、口腔照護行為與相關危險因子。病人不會主動把所有資訊告訴你。")

if "messages" not in st.session_state:
    st.session_state.messages = []

if "OPENAI_API_KEY" not in st.secrets:
    st.error("尚未設定 OPENAI_API_KEY。請先到 Streamlit Secrets 加入 API Key。")
    st.stop()

client = OpenAI(api_key=st.secrets["OPENAI_API_KEY"])

instructions = f"""
你正在進行口腔衛生教育的虛擬病人模擬。

你的唯一角色是「{case['patient_name']}」，{case['age']} 歲，{case['sex']}。
你必須忠實依照病例資料回答學生，不可跳出病人角色。

病例完整資料如下：
{json.dumps(case, ensure_ascii=False, indent=2)}

務必遵守 patient_rules。
特別注意：
1. hidden_information 只有在學生實際問到相關主題時才可以透露。
2. 不要主動教學生答案。
3. 不要幫學生做風險評估、診斷或治療計畫。
4. 回答使用自然繁體中文，口吻符合台灣高齡病人。
5. 若學生詢問你不可能知道的專業檢查結果，回答「這個我不太清楚，可能要請醫療人員檢查才知道」。
"""

for message in st.session_state.messages:
    with st.chat_message(message["role"]):
        st.markdown(message["content"])

prompt = st.chat_input("請輸入你想問病人的問題……")

if prompt:
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    api_history = [
        {"role": m["role"], "content": m["content"]}
        for m in st.session_state.messages
    ]

    try:
        response = client.responses.create(
            model="gpt-5-mini",
            instructions=instructions,
            input=api_history,
        )
        answer = response.output_text
    except Exception as e:
        st.error(f"API 呼叫失敗：{e}")
        st.stop()

    st.session_state.messages.append({"role": "assistant", "content": answer})
    with st.chat_message("assistant"):
        st.markdown(answer)

st.divider()

col1, col2 = st.columns(2)

with col1:
    if st.button("🔄 重新開始病例", use_container_width=True):
        st.session_state.messages = []
        st.rerun()

with col2:
    st.button(
        "📝 結束問診並評分（下一階段加入）",
        disabled=True,
        use_container_width=True,
    )

st.caption("目前為 MVP：只測試 AI 病人問診。請勿輸入真實病人可識別資料。")
