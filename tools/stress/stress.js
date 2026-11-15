// stress.js - CPU 烧机脚本（供算力调度对比测试使用）
const c = require('crypto');
let i = 0;
while (true) {
    c.createHash('sha256').update('stress' + (i++)).digest();
}
