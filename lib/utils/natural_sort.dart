/// 自然排序比较：数字段按数值比较（EP2 < EP10），其余按字符码比较。
int naturalCompare(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);
    final digitA = _isDigit(ca);
    final digitB = _isDigit(cb);
    if (digitA && digitB) {
      var endA = i;
      while (endA < a.length && _isDigit(a.codeUnitAt(endA))) {
        endA++;
      }
      var endB = j;
      while (endB < b.length && _isDigit(b.codeUnitAt(endB))) {
        endB++;
      }
      final numA = int.tryParse(a.substring(i, endA));
      final numB = int.tryParse(b.substring(j, endB));
      var cmp = 0;
      if (numA != null && numB != null) {
        cmp = numA.compareTo(numB);
        if (cmp == 0) {
          // 数值相同但前导零不同：位数多者排后（02 > 1 的语义不成立时保持稳定）
          cmp = (endA - i).compareTo(endB - j);
        }
      } else {
        cmp = a.substring(i, endA).compareTo(b.substring(j, endB));
      }
      if (cmp != 0) return cmp;
      i = endA;
      j = endB;
    } else {
      final cmp = ca.compareTo(cb);
      if (cmp != 0) return cmp;
      i++;
      j++;
    }
  }
  return a.length.compareTo(b.length);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
