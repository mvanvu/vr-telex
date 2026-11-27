"""Forms produced by English-list words (Telex reading of a word in en.txt) that the team judged to be real
Vietnamese syllables. Every other form such a word produces is removed from vi.txt, so the word is
restored as English. Judgement: forms attested in the syllable inventory read at generation time and
confirmed one by one, minus 56 non-words, plus 7 attested by the authors."""
REAL_EN_FORMS = set("""
bà bá bán báng bát bét bê bên bít bóng bóp bô bôm bôn bõ bú búa bún búng bút bơ bả bản bẻm bế bếp
bết bề bể bố bốn bốt bổ bớ bủ bủa bủn choé chá chái cháo chát chè ché chét chín chíp chít chói chóp
chúm chơ chả chải chảy chế chỏi chớ chủn cá cám cán cáp cát còi cói cóm cóp cót cô côn cú cúm cúp
cút cơ cả cọn cỏn cố cốp cốt cớ củ dái dám dán dáy dí dó dóc dún dăn dế dỏm dớn dứa dừa gá gáy gô
gôn gút gồ hoé há hái hám háng hát háy hé héo hí hím híp hít hó hóp hót hút hơ hải hẻ hẻo hỏn hố hốt
hồ hớ khán kén kên kít loà loá loé lái láp lát láy lã lén lét lê líp lít lóng lóp lót lôm lúng lút
lăn lơ lải lể lỏn lốm lốn lốp lốt lớ má mác mán mát mã mé mít mó móm món móp mót mô môn mút mĩ mơ
mơn mả mết mỏn mố mốt mổ mớ náy nét nít nó nôn nút nơ nảy nỏ oà oá oát oé oẻ quái quáy quét quên
quít quế rám ráp rát ráy rè ré rét rót rôm rúm rún rúng rút rơ rế rề rốt rồ rớ sác sái sán sáp sã sè
séc sét sê sên sít són sóng sót sù sú sún súp săn sĩ sơ sơn sải sẽ sếp sỉ sớ thê thí thít thón thú
thế toát toé trám trán tráp trê trót trút tá tái tám tán táng táo táp tát tã tém tét tê têm tên tín
tít tóm tóp tót tô tù tú tơ tả tảo tẻn tế tỏ tốt tớ tớn tủn vá ván vát vét vía víu vơ vả vảy vẽ vế
vớ xỏ á ái ám áp é ém ép ét ì í ít ò óp ú úp ý ơ ơn ải ảm ốp ớn ủn ứa ỷ
""".split())
