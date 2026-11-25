// Usage: npm run hash-admin-password -- "your-admin-password"
import bcrypt from "bcryptjs";

const password = process.argv[2];
if (!password || password.length < 8) {
  console.error("8자 이상의 관리자 비밀번호를 인자로 전달하세요.");
  process.exit(1);
}

const hash = await bcrypt.hash(password, 12);
console.log("Vercel 환경 변수 값:");
console.log(hash);
console.log("\n.env.local 에 넣을 값 ($ 이스케이프):");
console.log(`ADMIN_PASSWORD_HASH=${hash.replaceAll("$", "\\$")}`);