SRC=$(wildcard *.cpp)
OBJS=$(SRC:.cpp=.o)

all:    ${SRC}
	for file in ${SRC} ; do\
		${CXX} -c $$file ${INCLUDE} ${CXXFLAGS};\
	done
	mkdir -p ${LIBDIR}
	ar rvs ${LIBDIR}/libutil.a ${OBJS}

clean:
	rm -rf *.o
