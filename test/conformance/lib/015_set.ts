const st: Set<number> = new Set<number>();
const st2: Set<number> = st.add(1);
const has: boolean = st.has(1);
const removed: boolean = st.delete(1);
const size: number = st.size;
st.forEach((value) => { const v: number = value; });
st.clear();
